module SemanticLogger
  module Formatters
    # Maps a log entry to an OTLP LogRecord, as the Hash of its JSON encoding, which the `:otlp`
    # appender (Appender::Otlp) sends as OTLP/JSON or in the binary Protobuf encoding of OTLP (see
    # Otlp::Protobuf):
    #   timeUnixNano, observedTimeUnixNano: when the entry was logged, in nanoseconds.
    #   severityNumber, severityText:       the level, such as 9 and "info".
    #   body:                               the message, when the entry has one.
    #   attributes:                         the named tags and the payload, then the entry's own fields.
    #   traceId, spanId, flags:             the trace the entry was logged in (see Otlp::TraceContext).
    #
    # The attributes are named as by Formatters::OpenTelemetry, with these differences:
    # - A value keeps its structure: a Hash is a kvlistValue and an Array an arrayValue, at any depth,
    #   and an Array may mix types, since OTLP holds any of them, unlike the attributes that the
    #   OpenTelemetry SDK accepts (see Otlp::Values.any_value).
    # - The name of the logger is the instrumentation scope of the record, which the appender writes,
    #   so it is not the attribute `semantic_logger.name`.
    # - The process id is not the attribute `process.pid`: it is in the resource of every request,
    #   which the process that logged the entry sends itself.
    # - The named tags `trace_id` and `span_id` that the trace was taken from are its traceId and spanId,
    #   not attributes.
    #
    # A custom formatter for the `:otlp` appender subclasses this one, so that it returns a LogRecord.
    class Otlp < OpenTelemetry
      # The SeverityNumber of each level.
      SEVERITY_NUMBERS = {trace: 1, debug: 5, info: 9, warn: 13, error: 17, fatal: 21}.freeze

      # Returns [Hash] the LogRecord of the log entry.
      def call(log, logger)
        self.log    = log
        self.logger = logger

        trace  = SemanticLogger::Otlp::TraceContext.of(log)
        time   = SemanticLogger::Otlp::Values.nanoseconds(log.time)
        record = {
          timeUnixNano:         time,
          observedTimeUnixNano: time,
          severityNumber:       severity_number(log.level),
          severityText:         log.level.to_s
        }
        message         = body
        record[:body]   = {stringValue: SemanticLogger::Otlp::Values.text(message)} if message
        attributes      = attributes(trace)
        record[:attributes] = SemanticLogger::Otlp::Values.attributes(attributes) unless attributes.empty?
        add_trace(record, trace) if trace
        record
      end

      # Returns [Hash] the attributes, by name, as Formatters::OpenTelemetry names them, without
      # `semantic_logger.name` and `process.pid`, and without the named tags that the trace was taken
      # from.
      def attributes(trace = nil)
        attributes = {}
        named_tags = log.named_tags
        named_tags = named_tags.except(*trace.tags) if trace && !trace.tags.empty?
        add_logged(attributes, NAMED_TAGS_PREFIX, named_tags) if named_tags.is_a?(Hash)
        if log.payload?
          add_logged(attributes, PAYLOAD_PREFIX, log.payload.is_a?(Hash) ? log.payload : {payload: log.payload})
        end
        add_entry(attributes)
        add_exception(attributes)
        attributes
      end

      private

      # The attributes of the entry that it writes: not the logger's name, which is the scope of the
      # record, nor the pid, which the resource of each request holds, so that a payload or named tag key
      # of either name is sent as it is.
      OTLP_ENTRY_ATTRIBUTES = ENTRY_ATTRIBUTES.except(NAME, PROCESS_PID).freeze
      private_constant :OTLP_ENTRY_ATTRIBUTES

      def entry_attribute?(name)
        OTLP_ENTRY_ATTRIBUTES.key?(name)
      end

      def add_trace(record, trace)
        record[:traceId] = trace.trace_id
        record[:spanId]  = trace.span_id if trace.span_id
        record[:flags]   = trace.flags if trace.flags
      end

      # The value as it is: Otlp::Values.any_value writes any structure.
      def coerce_value(value)
        value
      end

      def severity_number(level)
        SEVERITY_NUMBERS.fetch(level, 0)
      end
    end
  end
end
