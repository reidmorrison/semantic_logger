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
      include SemanticLogger::Otlp::Exporter

      autoload :Encoder, "semantic_logger/metric/otlp/encoder"

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
      # The other options, and the environment variables that they take their defaults from, are those
      # of SemanticLogger::Otlp::Exporter, with METRICS for SIGNAL, such as
      # OTEL_EXPORTER_OTLP_METRICS_ENDPOINT, and posted to `v1/metrics` under `url:`. Its timeouts are
      # not bounded by OTEL_METRIC_EXPORT_TIMEOUT, which bounds a whole export.
      def initialize(interval: nil, **args, &)
        interval ||= SemanticLogger::Otlp::Environment.new(logger, otlp_signal).export_interval
        super
      end

      # Returns [SemanticLogger::Otlp::Signal] the metrics signal.
      def otlp_signal = SemanticLogger::Otlp::Signal::METRICS

      # Posts the snapshot in one request. Returns true once the server accepted it, and raises when it
      # did not, or could not be reached (see #metrics_retryable?).
      def write_metrics(snapshot)
        export(Encoder.request(snapshot, request_resource))
      end

      # Whether the snapshot that raised the exception is sent again with the next one (see
      # Metric::Snapshots#metrics_retryable?), as any OTLP request is (see
      # SemanticLogger::Otlp::Exporter#wrote_nothing?).
      def metrics_retryable?(exception)
        wrote_nothing?(exception)
      end
    end
  end
end
