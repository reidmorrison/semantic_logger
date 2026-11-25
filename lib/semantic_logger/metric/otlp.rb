# Send metrics to an OpenTelemetry collector, or any other server that receives OTLP/HTTP, in its
# binary Protobuf encoding (http/protobuf) by default, or as OTLP/JSON (http/json). Needs no
# OpenTelemetry gems, nor the google-protobuf gem.
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
#   SemanticLogger.add_appender(metric: :otlp, protocol: "http/json")
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

      # The attribute of the resource that holds the pid of the process that sends each request.
      PID_ATTRIBUTE = "process.pid".freeze

      # The options of `ssl:` that say which certificates to trust, so that the certificate variable
      # neither replaces nor adds to them, such as by loading its file into a shared `cert_store:`.
      TRUST_OPTIONS = %i[ca_file ca_path cert_store].freeze

      # An https url, whose connection the certificate variables apply to.
      HTTPS = /\Ahttps:/i

      # Returns [String] the path that the metrics are posted to.
      attr_reader :full_path

      # Returns [SemanticLogger::Otlp::Protocol] the encoding of the requests, http/protobuf or http/json.
      attr_reader :protocol

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
      #   The resource also holds the attributes of ENV["OTEL_RESOURCE_ATTRIBUTES"], other than
      #   `process.pid` (see below). Highest first:
      #   `resource_attributes:`; `application:`, `host:`, and `environment:` when given, and
      #   ENV["OTEL_SERVICE_NAME"]; ENV["OTEL_RESOURCE_ATTRIBUTES"]; then the defaults of
      #   SemanticLogger.application, .host, and .environment.
      #
      #   protocol: [String]
      #     How to encode each request: "http/protobuf", OTLP's binary Protobuf encoding, or "http/json",
      #     its JSON encoding. Any other raises ArgumentError.
      #     Default: ENV["OTEL_EXPORTER_OTLP_METRICS_PROTOCOL"], or else ENV["OTEL_EXPORTER_OTLP_PROTOCOL"],
      #     or else "http/protobuf". The environment's "grpc", which the appender cannot send, is taken as
      #     "http/protobuf", with a warning; any other value it does not know is ignored, with a warning.
      #
      #   interval: [Numeric]
      #     Seconds between requests.
      #     Default: ENV["OTEL_METRIC_EXPORT_INTERVAL"], in milliseconds, or else 60
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
      #     with the same name, in any case. A header of the environment that Appender::Http sets or
      #     relies on itself (see Appender::Http#reserved_header?), such as Content-Type, is left out,
      #     with a warning (see #add_otel_header). The headers of the environment, which often hold
      #     credentials, are sent to whatever url the appender posts to, including a `url:` or
      #     `endpoint:` given, as the OpenTelemetry specification asks; `header: {}` does not stop them,
      #     so to send none, do not set these variables for the process.
      #
      #   compress: true when OTEL_EXPORTER_OTLP_METRICS_COMPRESSION or OTEL_EXPORTER_OTLP_COMPRESSION is
      #     "gzip", false when it is "none".
      #
      #   ssl: for an https url only: `ca_file:` from OTEL_EXPORTER_OTLP_METRICS_CERTIFICATE or
      #     OTEL_EXPORTER_OTLP_CERTIFICATE, unless `ssl:` has a `ca_file:`, `ca_path:`, or `cert_store:`; and
      #     `cert:` and `key:` from the PEM files of OTEL_EXPORTER_OTLP_METRICS_CLIENT_CERTIFICATE and
      #     _CLIENT_KEY, or else OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE and _CLIENT_KEY, as a pair, unless
      #     `ssl:` has either. A variable whose option is given is not read. ArgumentError is raised for a
      #     file that cannot be read or parsed, for one of the client variables without the other, and for
      #     a key that is public, or not the certificate's. The client certificate file holds the
      #     client's own certificate first; any others in it are not sent. `ssl:` given as nil or false
      #     reads none of them.
      #
      #   open_timeout:, read_timeout: from OTEL_EXPORTER_OTLP_METRICS_TIMEOUT or OTEL_EXPORTER_OTLP_TIMEOUT,
      #     in milliseconds, 0 meaning no limit, only when neither option is given, so that one given
      #     keeps the default of Appender::Http for the other (see #otel_timeouts). Each bounds one wait,
      #     connecting or one read of the response, not the whole export, so OTEL_METRIC_EXPORT_TIMEOUT,
      #     which bounds the whole export, is not read.
      #
      # Every request also holds the `process.pid` of the process that sends it, so that the deltas of
      # each process, such as forked workers of the same application on the same host, are kept apart.
      def initialize(url: nil, endpoint: nil, application: nil, resource_attributes: nil, protocol: nil, **args, &)
        raise(ArgumentError, "Supply either url: or endpoint:, not both") if url && endpoint

        otel          = Environment.new(logger)
        @protocol     = SemanticLogger::Otlp::Protocol[protocol || otel.protocol]
        endpoint    ||= otel.endpoint unless url
        url         ||= otel.base_url || DEFAULT_URL
        application ||= otel.service_name
        given_header    = args[:header] || {}
        args[:header]   = @protocol.headers(given_header)
        args[:compress] = otel.compress if !args.key?(:compress) && !otel.compress.nil?
        args[:interval] = otel.export_interval if args[:interval].nil? && otel.export_interval
        args[:ssl]      = otel_ssl(otel, args.fetch(:ssl, {})) if HTTPS.match?((endpoint || url).to_s)

        super(url: endpoint || url, application: application, **otel_timeouts(otel, args).merge(args), &)

        add_otel_header(otel.headers, given_header)
        @full_path           = endpoint ? @path : "#{@path.delete_suffix('/')}/#{METRICS_PATH}"
        @resource_attributes = resource(otel.resource_attributes, resource_attributes).freeze
      end

      # Posts the snapshot in one request. Returns true once the server accepted it, and raises when it
      # did not, or could not be reached (see #metrics_retryable?).
      def write_metrics(snapshot)
        resource = resource_attributes.merge(PID_ATTRIBUTE => ::Process.pid) { |_key, given, _pid| given }
        request  = Encoder.request(snapshot, resource)
        logger.trace { JSON.generate(request) }
        post(protocol.encode(request, :ExportMetricsServiceRequest), full_path)
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
        partial = partial_success(response)
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

      # Returns [Hash|nil] the partialSuccess of the ExportMetricsServiceResponse in the body of the
      # response, nil when it has none, or cannot be read, for any reason (see
      # SemanticLogger::Otlp::Protocol#decode).
      def partial_success(response)
        fields  = protocol.decode(response.body, response["Content-Type"], :ExportMetricsServiceResponse)
        partial = fields && fields["partialSuccess"]
        partial if partial.is_a?(Hash)
      end

      # Returns [Hash] the attributes of the resource, with String keys: those of OTEL_RESOURCE_ATTRIBUTES
      # (from_env) replace the defaults, the application, host, and environment given (including the
      # service name of OTEL_SERVICE_NAME) replace them, and those of `resource_attributes:` (extra)
      # replace all of them. The process.pid of OTEL_RESOURCE_ATTRIBUTES is left out, with a warning,
      # since every process of a deployment shares its environment: the pid of the process that sends
      # each request keeps their deltas apart (see #write_metrics).
      def resource(from_env, extra)
        attributes = {"service.name" => application, "host.name" => host}
        attributes["deployment.environment.name"] = environment if environment
        if from_env.key?(PID_ATTRIBUTE)
          logger.warn("Ignoring #{PID_ATTRIBUTE} in OTEL_RESOURCE_ATTRIBUTES: each process sends its own")
        end
        attributes.merge!(from_env.except(PID_ATTRIBUTE))
        attributes.merge!(
          {"service.name" => @application, "host.name" => @host, "deployment.environment.name" => @environment}.compact
        )
        extra&.each { |key, value| attributes[key.to_s] = value }
        attributes
      end

      # Adds the headers of the environment (from_env) to those that Appender::Http sends, except those
      # whose name, in any case, since HTTP header names are case-insensitive, is that of a header
      # given, which wins, or of one that Appender::Http sets or relies on itself (see
      # Appender::Http#reserved_header?), which is kept; the names of those left out for it are reported
      # in one warning, never their values.
      def add_otel_header(from_env, given)
        given_names = given.keys.map { |name| name.to_s.downcase }
        added       = {}
        refused     = []
        from_env.each do |name, value|
          next if given_names.include?(name.downcase)

          if reserved_header?(name)
            refused << name
          else
            added[name] = value
          end
        end
        unless refused.empty?
          logger.warn(
            "Ignoring the header(s) #{refused.join(', ')} of the OTEL exporter headers variable: " \
            "the appender sets them itself"
          )
        end
        added.each { |name, value| replace_header(name, value) }
      end

      # Returns [Hash|nil|false] the `ssl:` options given, with the TLS options of the environment for
      # those not given: `ca_file:` (see Environment#ca_file), unless `ssl:` says which certificates to
      # trust otherwise (see TRUST_OPTIONS), and `cert:` and `key:` (see Environment#client_identity), as a
      # pair, unless `ssl:` gives either. An `ssl:` given that is not a Hash, such as nil, is returned as it
      # is, without reading any variable. Only asked for an https url.
      def otel_ssl(otel, given)
        return given unless given.is_a?(Hash)

        ssl = {}
        ssl[:ca_file] = otel.ca_file unless TRUST_OPTIONS.any? { |option| given.key?(option) }
        ssl.merge!(otel.client_identity) unless given.key?(:cert) || given.key?(:key)
        ssl.compact.merge(given)
      end

      # Returns [Hash] the open_timeout: and read_timeout: of Appender::Http that the timeout of the
      # environment sets (see Environment#timeout), both to it, only when neither is given (args), so
      # that one given keeps the default of Appender::Http for the other.
      #
      # OTLP's timeout bounds the whole export, but Net::HTTP has no such deadline, so it bounds each
      # wait on the server instead: connecting (open_timeout) and each read of the response
      # (read_timeout). A request can therefore take somewhat longer than the timeout in all. The
      # continue_timeout is left out: it applies only to a request sent with "Expect: 100-continue",
      # which the :otlp appender never sends.
      def otel_timeouts(otel, args)
        return {} if args.key?(:open_timeout) || args.key?(:read_timeout) || !otel.timeout?

        {open_timeout: otel.timeout, read_timeout: otel.timeout}
      end
    end
  end
end
