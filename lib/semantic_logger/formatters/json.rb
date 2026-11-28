require "json"
module SemanticLogger
  module Formatters
    # Writes each log entry as one JSON object, with the fields of Formatters::Raw, and the trace it was
    # logged in, so that a log agent that reads the file, such as the OpenTelemetry Collector's
    # `filelog` receiver, can link it to that trace:
    #
    #   trace_id:    [String] the trace id, as 32 lower case hex digits.
    #   span_id:     [String] the span id, as 16 lower case hex digits, when known.
    #   trace_flags: [String] the W3C trace flags, as 2 hex digits: "01" when the span is sampled,
    #                "00" when not. Only for the span that was current when it was logged.
    #
    # The trace is that of the span that was current on the thread that logged the entry, when the
    # opentelemetry-api gem is loaded, or else the `trace_id` and `span_id` named tags, when they hold
    # valid ids (see Otlp::TraceContext). The named tags are still written as they are. An entry
    # logged in no trace has none of these fields.
    class Json < Raw
      # Default JSON time format is ISO8601
      def initialize(time_format: :iso_8601, time_key: :timestamp, **args)
        super
      end

      # Returns log messages in JSON format
      def call(log, logger)
        hash = super
        trace_ids
        Utils.to_json(hash)
      end

      # Returns a batch of log messages as a single JSON array.
      def batch(logs, logger)
        "[#{logs.map { |log| call(log, logger) }.join(',')}]"
      end

      # The fields of the trace.
      TRACE_FIELDS = %i[trace_id span_id trace_flags].freeze

      # The trace id, span id, and trace flags of the entry, when it was logged in a trace. None of them
      # when a field method of a subclass already wrote any, such as from a trace of its own, so that the
      # three always belong to the same trace.
      def trace_ids
        return if TRACE_FIELDS.any? { |field| hash.key?(field) || hash.key?(field.name) }

        trace = SemanticLogger::Otlp::TraceContext.of(log)
        return unless trace

        hash[:trace_id]    = trace.trace_id
        hash[:span_id]     = trace.span_id if trace.span_id
        hash[:trace_flags] = format("%02x", trace.flags) if trace.flags
      end

      # Returns [Array<#call>] the capture of the trace that each entry was logged in, which it writes.
      def source_captures
        SemanticLogger::Otlp::TraceContext::CAPTURES
      end

      private

      # Cleans backtraces with the application's cleaner, as the text formatters do. Error services
      # receive the exception itself rather than this output, and the formatters written for a
      # particular service, such as Ecs, are not built on this one.
      def default_backtrace_cleaner
        true
      end
    end
  end
end
