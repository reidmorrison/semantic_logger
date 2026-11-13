module SemanticLogger
  module Formatters
    # Maps a log entry to an OpenTelemetry log record.
    #
    # Returns the keyword arguments for the OpenTelemetry Logs API's `Logger#on_emit`, other than
    # the context, which the appender captures:
    #   severity_text:   the level, such as "info"
    #   severity_number: the OpenTelemetry severity number of the level
    #   timestamp:       the time the entry was logged
    #   body:            the message, or nil when the entry has none
    #   attributes:      the named tags and the payload, then the entry's own fields
    #
    # Each named tag and payload key is an attribute of its own, the payload taking precedence
    # over a named tag of the same name. The entry's own fields use the attribute names of the
    # OpenTelemetry semantic conventions where there is one, and are otherwise prefixed with
    # "semantic_logger.", so that they do not collide with the application's keys:
    #   exception.type, exception.message, exception.stacktrace (with each exception that caused it)
    #   code.file.path, code.line.number (when the entry has a backtrace)
    #   thread.name, process.pid
    #   semantic_logger.name, semantic_logger.tags, semantic_logger.duration_ms,
    #   semantic_logger.metric, semantic_logger.metric_amount
    # A named tag or payload key named like one of these is prefixed with its source, as in
    # "payload.exception.type", so that logged data cannot replace or forge the entry's own fields.
    #
    # The host, application, and environment are not attributes: they describe the process, which
    # OpenTelemetry reports in the resource of every export. The process id is, since the resource
    # holds the id of the process that configured OpenTelemetry, not of a forked child.
    class OpenTelemetry < Base
      # Primitives allowed by OTLP logs in Ruby: String, Integer, Float, TrueClass, FalseClass.
      PRIMS = [String, Integer, Float, TrueClass, FalseClass].freeze

      # The entry's own attributes.
      EXCEPTION_TYPE       = "exception.type".freeze
      EXCEPTION_MESSAGE    = "exception.message".freeze
      EXCEPTION_STACKTRACE = "exception.stacktrace".freeze
      CODE_FILE_PATH       = "code.file.path".freeze
      CODE_LINE_NUMBER     = "code.line.number".freeze
      THREAD_NAME          = "thread.name".freeze
      PROCESS_PID          = "process.pid".freeze
      NAME                 = "semantic_logger.name".freeze
      TAGS                 = "semantic_logger.tags".freeze
      DURATION_MS          = "semantic_logger.duration_ms".freeze
      METRIC               = "semantic_logger.metric".freeze
      METRIC_AMOUNT        = "semantic_logger.metric_amount".freeze

      ENTRY_ATTRIBUTES = [
        EXCEPTION_TYPE, EXCEPTION_MESSAGE, EXCEPTION_STACKTRACE, CODE_FILE_PATH, CODE_LINE_NUMBER,
        THREAD_NAME, PROCESS_PID, NAME, TAGS, DURATION_MS, METRIC, METRIC_AMOUNT
      ].to_h { |name| [name, true] }.freeze

      # Prefixes for a named tag or payload key named like one of the entry's own attributes.
      NAMED_TAGS_PREFIX = "named_tags.".freeze
      PAYLOAD_PREFIX    = "payload.".freeze

      # Returns [Hash] the keyword arguments for `Logger#on_emit`.
      #
      # Unlike the JSON formatters there is no single `.to_json` boundary here:
      # the record is handed to the OTLP exporter, which requires valid UTF-8. Cleanse
      # the whole structure so binary / non UTF-8 strings cannot break the export.
      def call(log, logger)
        self.log    = log
        self.logger = logger

        Utils.encode_utf8(
          {
            severity_text:   log.level.to_s,
            severity_number: severity_number(log.level),
            timestamp:       log.time,
            body:            body,
            attributes:      attributes
          }
        )
      end

      # Returns [String] the message, or nil when the entry has none, such as a metric only entry,
      # or an exception logged without a message.
      def body
        log.cleansed_message if log.message
      end

      # Returns [Hash] the named tags and the payload, then the entry's own fields.
      #
      # A payload that is not a Hash, such as a String parsed from a request body, is submitted as a
      # single "payload" attribute.
      def attributes
        attributes = {}
        add_logged(attributes, NAMED_TAGS_PREFIX, log.named_tags) if log.named_tags.is_a?(Hash)
        if log.payload?
          add_logged(attributes, PAYLOAD_PREFIX, log.payload.is_a?(Hash) ? log.payload : {payload: log.payload})
        end
        add_entry(attributes)
        add_exception(attributes)
        attributes
      end

      private

      # Adds each key and value of a named tags or payload Hash, prefixing a key named like one of
      # the entry's own attributes with its source.
      def add_logged(attributes, prefix, hash)
        hash.each_pair do |key, value|
          name = Utils.encode_utf8_string(key.to_s)
          name = prefix + name if ENTRY_ATTRIBUTES.key?(name)
          add(attributes, name, value)
        end
      end

      def add_entry(attributes)
        add(attributes, NAME, log.name)
        add(attributes, THREAD_NAME, log.thread_name)
        add(attributes, PROCESS_PID, pid)

        file, line = log.file_name_and_line
        if file
          add(attributes, CODE_FILE_PATH, file)
          add(attributes, CODE_LINE_NUMBER, line)
        end

        add(attributes, TAGS, log.tags) if log.tags && !log.tags.empty?
        add(attributes, DURATION_MS, log.duration)
        add(attributes, METRIC, log.metric)
        add(attributes, METRIC_AMOUNT, log.metric_amount)
      end

      # The logged exception, with the backtrace of each exception that caused it in its stacktrace.
      def add_exception(attributes)
        exception = log.exception
        return unless exception

        add(attributes, EXCEPTION_TYPE, exception.class.name)
        add(attributes, EXCEPTION_MESSAGE, exception.message)
        stacktrace = exception_backtrace
        add(attributes, EXCEPTION_STACKTRACE, stacktrace) unless stacktrace.empty?
      end

      # Adds the value as an attribute, unless it is nil.
      def add(attributes, name, value)
        attributes[name] = coerce_value(value) unless value.nil?
      end

      # An attribute value: a primitive, or an Array of them.
      def coerce_value(v)
        v.is_a?(Array) ? v.map { |e| coerce_element(e) }.compact : coerce_element(v)
      end

      # A primitive as-is, and anything else as a String: a structure (such as a Hash, Struct, or
      # Set) as JSON, depth-limited and repaired by Utils.to_json, rather than its #to_s, which is
      # its #inspect and would expose the instance variables of any object it holds.
      def coerce_element(v)
        case v
        when *PRIMS, NilClass then v
        else Utils.structure?(v) ? Utils.to_json(v) : v.to_s
        end
      end

      def severity_number(severity)
        case severity
        when :trace
          ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_TRACE
        when :debug
          ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_DEBUG
        when :info
          ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_INFO
        when :warn
          ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_WARN
        when :error
          ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_ERROR
        when :fatal
          ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_FATAL
        else
          ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_UNSPECIFIED
        end
      end
    end
  end
end
