# Send metrics to an OpenTelemetry collector, or any other server that receives OTLP/HTTP, as
# OTLP/JSON. Needs no OpenTelemetry gems.
#
# Example:
#   SemanticLogger.add_appender(metric: :otlp)
#
#   SemanticLogger.add_appender(
#     metric:   :otlp,
#     url:      "https://otlp.example.com",
#     header:   {"Authorization" => "Bearer TOKEN"},
#     interval: 10
#   )
#
# Each snapshot of metrics (see Metric::Snapshots) is posted as one ExportMetricsServiceRequest to
# `<url>/v1/metrics`: counters as monotonic sums, and histograms as base-2 exponential histograms, both
# with delta temporality. See Otlp::Encoder.
#
# Responses:
# As for Appender::Http. A snapshot that the server asked to send again later (408, 429, or 503), or
# that could not be sent since the server could not be reached, is kept and sent with the next
# snapshot, merged with it, up to MAX_RESENDS times; it is then discarded, as is a snapshot that
# fails for any other reason, which is reported on the internal logger. A partial success, where the
# server stored only some of the data points, is reported on the internal logger, and not sent again.
module SemanticLogger
  module Metric
    class Otlp < SemanticLogger::Appender::Http
      include SemanticLogger::Metric::Snapshots

      autoload :Encoder, "semantic_logger/metric/otlp/encoder"

      # Base url of an OTLP/HTTP receiver, when neither `url:` nor `endpoint:` is given, nor set in the
      # environment.
      DEFAULT_URL = "http://localhost:4318".freeze

      # Path of the metrics requests, under the path of the base url.
      METRICS_PATH = "v1/metrics".freeze

      # Most snapshots in a row that are kept to be sent again with the next one (see #write_metrics).
      MAX_RESENDS = 3

      # Returns [String] the path that the metrics are posted to.
      attr_reader :full_path

      # Returns [Hash] the attributes of the resource, other than process.pid, which is the process's
      # own when each request is sent.
      attr_reader :resource_attributes

      # Create an OTLP/HTTP metric appender.
      #
      # Parameters:
      #   url: [String]
      #     Base url of the OTLP/HTTP receiver. The metrics are posted to `v1/metrics` under its path.
      #     Default: ENV["OTEL_EXPORTER_OTLP_ENDPOINT"], or else "http://localhost:4318"
      #
      #   endpoint: [String]
      #     Full url to post the metrics to, used as it is, instead of `url:`.
      #     Default: ENV["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"], unless `url:` is given
      #
      #   application: [String]
      #     Name of this application: the `service.name` of the resource.
      #     Default: ENV["OTEL_SERVICE_NAME"], or else SemanticLogger.application
      #
      #   host: [String]
      #     Name of this host: the `host.name` of the resource.
      #     Default: SemanticLogger.host
      #
      #   environment: [String]
      #     Name of this environment: the `deployment.environment.name` of the resource, which has none
      #     when there is no environment.
      #     Default: SemanticLogger.environment
      #
      #   resource_attributes: [Hash]
      #     More attributes of the resource, which replace those above with the same key.
      #     Example: {"service.version" => "1.2.3"}
      #
      #   interval: [Numeric]
      #     Seconds between requests.
      #     Default: 60
      #
      #   internal_metrics: [true|false]
      #     Whether to send Semantic Logger's own metrics too.
      #     Default: false
      #
      # The other options are those of Appender::Http, such as `header:` for the headers of each request,
      # such as one with credentials, `compress: true` to send the requests compressed with gzip, `ssl:`,
      # `proxy_url:`, and the timeouts.
      #
      # Every request also holds the `process.pid` of the process that sends it, so that the deltas of
      # each process, such as forked workers of the same application on the same host, are kept apart.
      def initialize(url: nil, endpoint: nil, application: nil, resource_attributes: nil, **args, &)
        raise(ArgumentError, "Supply either url: or endpoint:, not both") if url && endpoint

        endpoint ||= env("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT") unless url
        url      ||= env("OTEL_EXPORTER_OTLP_ENDPOINT") || DEFAULT_URL
        application ||= env("OTEL_SERVICE_NAME")

        super(url: endpoint || url, application: application, **args, &)

        @full_path           = endpoint ? @path : "#{@path.delete_suffix('/')}/#{METRICS_PATH}"
        @resource_attributes = resource(resource_attributes).freeze
        @unsent              = nil
        @resends             = 0
      end

      # Posts the snapshot, merged with the one that it is sending again, if any. Returns true once the
      # server accepted it.
      #
      # When the server stored none of it, and it is worth sending again later (see
      # Appender::Http#wrote_nothing?), it is kept and reported on the internal logger, rather than
      # raised, up to MAX_RESENDS times in a row. Raises any other error, after which the snapshot is
      # discarded.
      def write_metrics(snapshot)
        snapshot = @unsent.merge(snapshot) if @unsent
        @unsent  = nil
        resource = resource_attributes.merge("process.pid" => ::Process.pid) { |_key, given, _pid| given }
        body     = Encoder.call(snapshot, resource)
        logger.trace(body)
        post(body, full_path)
        @resends = 0
        true
      rescue StandardError => e
        raise unless wrote_nothing?(e) && @resends < MAX_RESENDS

        @resends += 1
        @unsent   = snapshot
        logger.warn("Could not send metrics to #{redacted_url}, sending them again with the next ones", e)
        false
      end

      private

      # Reports a partial success, where the server stored only some of the data points, from the body of
      # a 2xx response, on the internal logger. They are not sent again. Returns true.
      def accepted(response)
        partial = partial_success(response.body)
        return true unless partial

        rejected = partial["rejectedDataPoints"].to_i
        message  = partial["errorMessage"]
        return true if rejected.zero? && (message.nil? || message.empty?)

        logger.warn(
          "#{redacted_url} rejected #{rejected} metric data point(s): " \
          "#{message.to_s[0, MAX_LOGGED_RESPONSE_BODY].inspect}"
        )
        true
      end

      # Returns [Hash|nil] the partialSuccess of an ExportMetricsServiceResponse, nil when the body has
      # none, or is not JSON.
      def partial_success(body)
        return if body.nil? || body.empty?

        partial = JSON.parse(body)
        partial = partial["partialSuccess"] if partial.is_a?(Hash)
        partial if partial.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      # Returns [Hash] the attributes of the resource, with String keys.
      def resource(extra)
        attributes = {"service.name" => application, "host.name" => host}
        attributes["deployment.environment.name"] = environment if environment
        extra&.each { |key, value| attributes[key.to_s] = value }
        attributes
      end

      # Returns [String|nil] the value of the environment variable, nil when it is not set or blank.
      def env(name)
        value = ENV.fetch(name, nil)
        value unless value.nil? || value.strip.empty?
      end
    end
  end
end
