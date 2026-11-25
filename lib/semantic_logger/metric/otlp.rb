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
# with delta temporality, with one ScopeMetrics for each logger that recorded metrics, its
# instrumentation scope (the meter) named after it, such as "MyApp::Orders", as the log records of
# `appender: :otlp` are. Semantic Logger's own metrics are in the scope "SemanticLogger", with the gem's
# version. See Otlp::Encoder.
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
      include SemanticLogger::Otlp::Exporter

      autoload :Encoder, "semantic_logger/metric/otlp/encoder"

      # Seconds that the export of each snapshot may take in all, unless `export_timeout:` or
      # OTEL_METRIC_EXPORT_TIMEOUT says otherwise: 30, the default of the OpenTelemetry metrics SDK.
      DEFAULT_EXPORT_TIMEOUT = 30.0

      # Create an OTLP/HTTP metric appender.
      #
      # Parameters:
      #   interval: [Numeric]
      #     Seconds between requests.
      #     Default: ENV["OTEL_METRIC_EXPORT_INTERVAL"], in milliseconds, or else 60
      #
      #   internal_metrics: [true|false]
      #     Whether to send Semantic Logger's own metrics too.
      #     Default: false
      #
      #   export_timeout: [Numeric]
      #     Seconds that the export of each snapshot may take in all, from encoding it to the end of
      #     the response; 0 for no limit. Each wait on the server, connecting, sending the request, and
      #     each read of the response, is bounded by the time left, as well as by its own timeout, such
      #     as `read_timeout:` (see Appender::Http#post). A snapshot whose export ran out of time before
      #     its request was sent is sent with the next one; once sent, it is discarded, since the server
      #     may have stored it.
      #     Default: ENV["OTEL_METRIC_EXPORT_TIMEOUT"], in milliseconds, 0 meaning no limit, or else 30
      #
      # The other options, and the environment variables that they take their defaults from, are those
      # of SemanticLogger::Otlp::Exporter, with METRICS for SIGNAL, such as
      # OTEL_EXPORTER_OTLP_METRICS_ENDPOINT, and posted to `v1/metrics` under `url:`.
      def initialize(interval: nil, export_timeout: nil, **args, &)
        otel            = SemanticLogger::Otlp::Environment.new(logger, otlp_signal)
        interval      ||= otel.export_interval
        @export_timeout = export_timeout_option(export_timeout, otel)
        super(interval: interval, **args, &)
      end

      # Returns [Float|nil] the seconds that the export of each snapshot may take in all, nil for no
      # limit (see `export_timeout:`).
      attr_reader :export_timeout

      # Returns [true]: each logger's metrics are sent with the logger's name as their instrumentation
      # scope (see Encoder).
      def metric_scopes? = true

      # Returns [SemanticLogger::Otlp::Signal] the metrics signal.
      def otlp_signal = SemanticLogger::Otlp::Signal::METRICS

      # Posts the snapshot in one request. Returns true once the server accepted it, and raises when it
      # did not, or could not be reached (see #metrics_retryable?).
      def write_metrics(snapshot)
        deadline = export_timeout && (::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + export_timeout)
        export(Encoder.request(snapshot, request_resource), deadline: deadline)
      end

      # Whether the snapshot that raised the exception is sent again with the next one (see
      # Metric::Snapshots#metrics_retryable?), as any OTLP request is (see
      # SemanticLogger::Otlp::Exporter#wrote_nothing?).
      def metrics_retryable?(exception)
        wrote_nothing?(exception)
      end

      private

      # Returns [Float|nil] the export timeout in seconds, nil for no limit: that given, 0 meaning no
      # limit, or else that of the environment (see Otlp::Environment#export_timeout), or else
      # DEFAULT_EXPORT_TIMEOUT. Raises ArgumentError for one given that is not a Numeric of 0 or more.
      def export_timeout_option(given, otel)
        if given.nil?
          return otel.export_timeout? ? otel.export_timeout : DEFAULT_EXPORT_TIMEOUT
        end
        unless given.is_a?(Numeric) && given.real? && given.finite? && !given.negative?
          raise(ArgumentError, "export_timeout: must be a number of seconds, 0 or more: #{given.inspect}")
        end

        given.zero? ? nil : given.to_f
      end
    end
  end
end
