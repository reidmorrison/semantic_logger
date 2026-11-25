require "json"

module SemanticLogger
  module Formatters
    # Writes each log entry as one line of OTLP JSON Lines: a LogsData in the OTLP/JSON encoding, holding
    # the resource of the process, the instrumentation scope of the entry's logger, and its LogRecord, as
    # the `:otlp` appender sends it (see Formatters::Otlp). The OpenTelemetry Collector's `otlpjsonfile`
    # receiver reads such a file, as the OTLP File Exporter specification describes:
    #
    #   SemanticLogger.add_appender(file_name: "log/otlp.jsonl", formatter: :otlp_json_lines)
    #
    # Rotating the file is left to the file appender, such as with `reopen_period:` or `reopen_size:`.
    #
    # Each line holds at most `max_bytes:`, 1 MiB by default, the most that the receiver reads of one line
    # unless told otherwise. A longer line is cut to fit, in order, until it does: first the stack trace
    # of its exception, then its body, each ending with TRUNCATED; then its attributes, the largest first,
    # counted in the record's droppedAttributesCount.
    #
    # The resource is that of the `:otlp` appender (see Otlp::Resource): `application:`, `host:`, and
    # `environment:` given win over OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES, which win over those of
    # the appender, such as SemanticLogger.application. Each line holds the `process.pid` of the process
    # that writes it.
    class OtlpJsonLines
      # The most bytes of one line, when `max_bytes:` is not given: the default `max_log_size` of the
      # Collector's file receivers.
      DEFAULT_MAX_BYTES = 1024 * 1024

      # Ends the text of a value that was cut to fit the line.
      TRUNCATED = "...[truncated]".freeze

      # Returns [Integer] the most bytes of one line.
      attr_reader :max_bytes

      # Returns [SemanticLogger::Formatters::Otlp] the formatter that maps each entry to its LogRecord.
      attr_reader :record_formatter

      # Parameters:
      #   max_bytes: [Integer]
      #     The most bytes of one line, without its newline.
      #     Default: DEFAULT_MAX_BYTES (1 MiB)
      #
      #   application: [String]
      #     The `service.name` of the resource.
      #     Default: ENV["OTEL_SERVICE_NAME"], or else the appender's application
      #
      #   host: [String]
      #     The `host.name` of the resource.
      #     Default: the appender's host
      #
      #   environment: [String]
      #     The `deployment.environment.name` of the resource.
      #     Default: the appender's environment, if any
      #
      #   resource_attributes: [Hash]
      #     More attributes of the resource, which replace those above with the same key.
      #
      #   record_formatter: [SemanticLogger::Formatters::Otlp]
      #     Maps each entry to its LogRecord.
      #     Default: SemanticLogger::Formatters::Otlp.new(flatten:)
      #
      #   flatten: [true|false]
      #     Whether to flatten the Hashes of the payload and named tags (see Formatters::Otlp), when no
      #     `record_formatter:` is given.
      #     Default: true
      def initialize(max_bytes: DEFAULT_MAX_BYTES, application: nil, host: nil, environment: nil,
                     resource_attributes: nil, record_formatter: nil, flatten: true)
        unless max_bytes.is_a?(Integer) && max_bytes.positive?
          raise(ArgumentError, "max_bytes: must be a positive Integer, not: #{max_bytes.inspect}")
        end

        @max_bytes           = max_bytes
        @given               = {application: application, host: host, environment: environment}.freeze
        @resource_attributes = resource_attributes
        @record_formatter    = record_formatter || Formatters::Otlp.new(flatten: flatten)
        @resources           = Concurrent::Map.new
      end

      # Returns [String] the line of the log entry, without a newline.
      def call(log, logger)
        record   = record_formatter.call(log, logger)
        resource = resource_for(logger).process_attributes
        line     = line(resource, log.name, record)
        line.bytesize <= max_bytes ? line : fit(resource, log.name, record, line)
      end

      # Returns true: each record carries the trace it was logged in.
      def trace_context?
        true
      end

      private

      # Returns [Otlp::Resource] the resource of the lines written for the appender, built once for each.
      def resource_for(appender)
        TrapSafe.compute_if_absent(@resources, appender || :none) { build_resource(appender) }
      end

      def build_resource(appender)
        internal = appender.respond_to?(:logger) ? appender.logger : SemanticLogger::Processor.logger
        # Without an appender, SemanticLogger's own settings, which it answers in the same way.
        source   = appender || SemanticLogger
        defaults = {application: source.application, host: source.host, environment: source.environment}
        SemanticLogger::Otlp::Resource.new(
          otel:       SemanticLogger::Otlp::Environment.new(internal, SemanticLogger::Otlp::Signal::LOGS),
          defaults:   defaults,
          given:      @given,
          attributes: @resource_attributes,
          logger:     internal
        )
      end

      def line(resource, name, record)
        JSON.generate(SemanticLogger::Otlp::LogsData.request(resource, {name => [record]}))
      end

      # Returns [String] the line, with the record cut until it fits, as the class describes. A line that
      # still does not fit once the record has no attributes left is returned as it is.
      def fit(resource, name, record, line)
        [stack_trace_value(record), record[:body]].each do |value|
          line = line(resource, name, record) if cut(value, line.bytesize - max_bytes)
          return line if line.bytesize <= max_bytes
        end
        drop_attributes(record, line.bytesize - max_bytes)
        line(resource, name, record)
      end

      # Returns [Hash|nil] the AnyValue of the stack trace attribute of the record.
      def stack_trace_value(record)
        attribute = record[:attributes]&.find { |key_value| key_value[:key] == OpenTelemetry::EXCEPTION_STACKTRACE }
        attribute && attribute[:value]
      end

      # Cuts the text of the AnyValue by at least `excess` bytes of the line, ending it with TRUNCATED.
      # Each byte of text is at least one byte of JSON, so cutting as many bytes from the text removes at
      # least as many from the line. Returns whether it cut anything.
      def cut(value, excess)
        text = value && value[:stringValue]
        return false unless text.is_a?(String) && text.bytesize > TRUNCATED.bytesize

        keep                = text.bytesize - excess - TRUNCATED.bytesize
        kept                = keep.positive? ? text.byteslice(0, keep).scrub("") : ""
        value[:stringValue] = "#{kept}#{TRUNCATED}"
        true
      end

      # Drops the attributes of the record, the largest first, until at least `excess` bytes are gone,
      # counting them in droppedAttributesCount.
      def drop_attributes(record, excess)
        attributes = record[:attributes]
        return unless attributes

        sized   = attributes.map { |attribute| [JSON.generate(attribute).bytesize + 1, attribute] }
        dropped = 0
        sized.sort_by { |size, _| -size }.each do |size, attribute|
          break if excess <= 0

          attributes.delete(attribute)
          excess  -= size
          dropped += 1
        end
        record.delete(:attributes) if attributes.empty?
        record[:droppedAttributesCount] = dropped if dropped.positive?
      end
    end
  end
end
