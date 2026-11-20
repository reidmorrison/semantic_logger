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
# As for Appender::Http, except that a 502 or 504 is retryable too, as OTLP/HTTP requires. A snapshot
# that the server asked to send again later (408, 429, 502, 503, or 504), or that could not be sent
# since the server could not be reached, is kept and sent with the next snapshot, merged with it (see
# #metrics_retryable? and Metric::Snapshots); a snapshot that fails for any other reason is discarded,
# and reported on the internal logger. A partial success, where the server stored only some of the
# data points, is reported on the internal logger, and not sent again.
#
# A 502 or 504 from a proxy or load balancer in front of the receiver may come after the receiver
# stored the snapshot, such as when its answer took longer than the proxy waits. Sending it again, as
# OTLP/HTTP requires, then counts its data points twice.
module SemanticLogger
  module Metric
    class Otlp < SemanticLogger::Appender::Http
      include SemanticLogger::Metric::Snapshots

      autoload :Encoder, "semantic_logger/metric/otlp/encoder"
      autoload :Environment, "semantic_logger/metric/otlp/environment"

      # Base url of an OTLP/HTTP receiver, when neither `url:` nor `endpoint:` is given, nor set in the
      # environment.
      DEFAULT_URL = "http://localhost:4318".freeze

      # Path of the metrics requests, under the path of the base url.
      METRICS_PATH = "v1/metrics".freeze

      # Status codes of the responses, besides those of Appender::Http::ResponseError#retry_later?, after
      # which OTLP/HTTP has a request sent again (see #metrics_retryable?).
      RETRYABLE_CODES = [502, 504].freeze

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
      #   The resource also holds the attributes of ENV["OTEL_RESOURCE_ATTRIBUTES"]. Highest first:
      #   `resource_attributes:`; `application:`, `host:`, and `environment:` when given, and
      #   ENV["OTEL_SERVICE_NAME"]; ENV["OTEL_RESOURCE_ATTRIBUTES"]; then the defaults of
      #   SemanticLogger.application, .host, and .environment.
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
      # `proxy_url:`, and the timeouts. These take defaults from the environment too, each from the
      # variable of the metrics signal, or else from the generic one (see Otlp::Environment):
      #
      #   header: from OTEL_EXPORTER_OTLP_METRICS_HEADERS or OTEL_EXPORTER_OTLP_HEADERS, as `name=value`
      #     pairs separated by commas, percent-decoded. A header given wins over one of the environment
      #     with the same name, in any case.
      #
      #   compress: true when OTEL_EXPORTER_OTLP_METRICS_COMPRESSION or OTEL_EXPORTER_OTLP_COMPRESSION is
      #     "gzip", false when it is "none".
      #
      #   open_timeout:, read_timeout: from OTEL_EXPORTER_OTLP_METRICS_TIMEOUT or OTEL_EXPORTER_OTLP_TIMEOUT,
      #     in milliseconds, 0 meaning no limit (see #otel_timeouts).
      #
      # Every request also holds the `process.pid` of the process that sends it, so that the deltas of
      # each process, such as forked workers of the same application on the same host, are kept apart.
      def initialize(url: nil, endpoint: nil, application: nil, resource_attributes: nil, **args, &)
        raise(ArgumentError, "Supply either url: or endpoint:, not both") if url && endpoint

        otel          = Environment.new(logger)
        endpoint    ||= otel.endpoint unless url
        url         ||= otel.base_url || DEFAULT_URL
        application ||= otel.service_name
        args[:header]   = otel_header(otel, args[:header] || {})
        args[:compress] = otel.compress if !args.key?(:compress) && !otel.compress.nil?

        super(url: endpoint || url, application: application, **otel_timeouts(otel).merge(args), &)

        @full_path           = endpoint ? @path : "#{@path.delete_suffix('/')}/#{METRICS_PATH}"
        @resource_attributes = resource(otel.resource_attributes, resource_attributes).freeze
      end

      # Posts the snapshot in one request. Returns true once the server accepted it, and raises when it
      # did not, or could not be reached (see #metrics_retryable?).
      def write_metrics(snapshot)
        resource = resource_attributes.merge("process.pid" => ::Process.pid) { |_key, given, _pid| given }
        body     = Encoder.call(snapshot, resource)
        logger.trace(body)
        post(body, full_path)
      end

      # Whether the snapshot that raised the exception is sent again with the next one (see
      # Metric::Snapshots#metrics_retryable?): the server asked to send it again later, or it was
      # never sent (see Appender::Http#wrote_nothing?), so that the server stored none of it; or the
      # server answered 502 or 504, which OTLP/HTTP retries too (see RETRYABLE_CODES), although a
      # proxy may answer either after the receiver behind it stored the snapshot, which is then
      # counted twice.
      def metrics_retryable?(exception)
        return true if wrote_nothing?(exception)

        exception.is_a?(ResponseError) && RETRYABLE_CODES.include?(exception.code)
      end

      private

      # Reports a partial success, where the server stored only some of the data points, from the body of
      # a 2xx response, on the internal logger. They are not sent again. Returns true, whatever the
      # body holds: a rejectedDataPoints that is not a number counts as 0, and an errorMessage that is
      # not a String is reported as its text.
      def accepted(response)
        partial = partial_success(response.body)
        return true unless partial

        rejected = rejected_count(partial["rejectedDataPoints"]) || 0
        message  = partial["errorMessage"]
        message  = message.nil? ? "" : message.to_s
        return true if rejected.zero? && message.empty?

        logger.warn(
          "#{redacted_url} rejected #{rejected} metric data point(s): " \
          "#{message[0, MAX_LOGGED_RESPONSE_BODY].inspect}"
        )
        true
      end

      # Returns [Integer] the rejectedDataPoints of a partialSuccess: an Integer, or a String of decimal
      # digits, as the Protobuf JSON mapping writes an int64; 0 for anything else.
      def rejected_count(value)
        count = value.is_a?(String) ? Integer(value, 10, exception: false) : Integer(value, exception: false)
        count || 0
      end

      # Returns [Hash|nil] the partialSuccess of an ExportMetricsServiceResponse, nil when the body has
      # none, or cannot be parsed as JSON, for any reason.
      def partial_success(body)
        return if body.nil? || body.empty?

        partial = JSON.parse(body)
        partial = partial["partialSuccess"] if partial.is_a?(Hash)
        partial if partial.is_a?(Hash)
      rescue StandardError
        nil
      end

      # Returns [Hash] the attributes of the resource, with String keys: those of OTEL_RESOURCE_ATTRIBUTES
      # (from_env) replace the defaults, the application, host, and environment given (including the
      # service name of OTEL_SERVICE_NAME) replace them, and those of `resource_attributes:` (extra)
      # replace all of them.
      def resource(from_env, extra)
        attributes = {"service.name" => application, "host.name" => host}
        attributes["deployment.environment.name"] = environment if environment
        attributes.merge!(from_env)
        attributes.merge!(
          {"service.name" => @application, "host.name" => @host, "deployment.environment.name" => @environment}.compact
        )
        extra&.each { |key, value| attributes[key.to_s] = value }
        attributes
      end

      # Returns [Hash] the headers given, and those of the environment whose name none given has, in any
      # case, since HTTP header names are case-insensitive.
      def otel_header(otel, given)
        names = given.keys.map { |name| name.to_s.downcase }
        otel.headers.reject { |name, _value| names.include?(name.downcase) }.merge(given)
      end

      # Returns [Hash] the Appender::Http timeouts that the timeout of the environment sets, none when it
      # sets none. OTLP's timeout bounds the whole export, but Net::HTTP has no such deadline, so it
      # bounds each wait on the server instead: connecting (open_timeout) and each read of the response
      # (read_timeout). A request can therefore take somewhat longer than the timeout in all. The
      # continue_timeout is left as it is: it applies only to a request sent with
      # "Expect: 100-continue", which this appender never sends.
      def otel_timeouts(otel)
        return {} unless otel.timeout?

        {open_timeout: otel.timeout, read_timeout: otel.timeout}
      end
    end
  end
end
