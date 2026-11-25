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
    # - A Hash in the payload or named tags is flattened, by default, into an attribute for each of its
    #   values, its keys joined with ".", at any depth, as the OpenTelemetry semantic conventions name
    #   attributes, so that every backend can query each value: `{request: {zip_code: "10001"}}` is the
    #   attribute "request.zip_code". With `flatten: false` it is a kvlistValue. An Array stays an
    #   arrayValue, a Hash within it a kvlistValue, and an Array may mix types, since OTLP holds any of
    #   them, unlike the attributes that the OpenTelemetry SDK accepts (see Otlp::Values.any_value).
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

      # The most flattened keys that collided with another key that it warns about, once each.
      MAX_COLLISION_WARNINGS = 100

      # Returns [true|false] whether it flattens the Hashes of the payload and named tags: true unless
      # `flatten: false` was given, such as for a subclass whose #initialize does not call super.
      def flatten = @flatten != false

      # Parameters:
      #   flatten: [true|false]
      #     Whether to flatten each Hash of the payload and named tags into an attribute for each of its
      #     values, its keys joined with "." (see the class).
      #     Default: true
      #
      # The other options are those of Formatters::Base.
      def initialize(flatten: true, **args)
        super(**args)
        @flatten = flatten
        @warned  = Concurrent::Map.new
      end

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

      # Adds the named tags or payload, flattened when #flatten is true: each Hash value is replaced with
      # the values it holds, under its key and theirs joined with ".", at any depth. Each flattened name
      # is then prefixed as Formatters::OpenTelemetry#logged_name does, so that a flattened name such as
      # "thread.name" never replaces the entry's own attribute; only that value is prefixed, not the
      # others of its Hash. When a name, once flattened and prefixed, is that of another value of the same
      # Hash, such as the key "a.b" and {a: {b: 1}}, the first is kept, and the internal logger warns once
      # for the name. A nil value is left out, as it is without flattening.
      def add_logged(attributes, prefix, hash)
        return super unless flatten

        added = {}
        hash.each_pair do |key, value|
          # A structure, such as a Struct, becomes a Hash or an Array, once, without cycles.
          value = Utils.json_safe(value) if Utils.structure?(value)
          add_flat(attributes, added, prefix, SemanticLogger::Otlp::Values.text(key), value)
        end
      end

      def add_flat(attributes, added, prefix, name, value)
        if value.is_a?(Hash) && !value.empty?
          value.each_pair do |key, item|
            add_flat(attributes, added, prefix, "#{name}.#{SemanticLogger::Otlp::Values.text(key)}", item)
          end
          return
        end
        return if value.nil?

        name = logged_name(prefix, name)
        return collided(name) if added.key?(name)

        added[name] = true
        add(attributes, name, value)
      end

      def collided(name)
        warned = (@warned ||= Concurrent::Map.new)
        return if warned.size >= MAX_COLLISION_WARNINGS || warned.put_if_absent(name, true)

        logger&.logger&.warn("Left out a value of the attribute #{name.inspect}, which another value of the " \
                             "same Hash, once flattened, already has")
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
