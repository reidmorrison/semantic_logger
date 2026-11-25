module SemanticLogger
  module Otlp
    # A signal of OTLP, metrics or logs: the names that set its exporter apart from those of the other
    # signals, which Environment and Exporter ask for.
    #
    #   kind:          what the appender of the signal is, in a message, such as "metric".
    #   variable:      the part of the name of its environment variables, such as "METRICS" in
    #                  OTEL_EXPORTER_OTLP_METRICS_ENDPOINT.
    #   path:          the path of its requests under the base url, such as "v1/metrics".
    #   request:       the message of its requests (see Schema).
    #   response:      the message of the responses to them.
    #   rejected:      the field of a partial success that counts what the server rejected.
    #   rejected_noun: what that field counts, in a message.
    Signal = Struct.new(:kind, :variable, :path, :request, :response, :rejected, :rejected_noun, keyword_init: true)

    class Signal
      METRICS = new(
        kind:          "metric",
        variable:      "METRICS",
        path:          "v1/metrics",
        request:       :ExportMetricsServiceRequest,
        response:      :ExportMetricsServiceResponse,
        rejected:      "rejectedDataPoints",
        rejected_noun: "metric data point(s)"
      ).freeze

      LOGS = new(
        kind:          "log",
        variable:      "LOGS",
        path:          "v1/logs",
        request:       :ExportLogsServiceRequest,
        response:      :ExportLogsServiceResponse,
        rejected:      "rejectedLogRecords",
        rejected_noun: "log record(s)"
      ).freeze
    end
  end
end
