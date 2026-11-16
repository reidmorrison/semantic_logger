begin
  require "opentelemetry/logs"
rescue LoadError
  raise LoadError,
        "Gem opentelemetry-logs-sdk is required for logging to Open Telemetry. " \
        'Please add the gem "opentelemetry-logs-sdk" to your Gemfile.'
end

# Open Telemetry Appender
#
#   Writes log entries to Open Telemetry, as log records through its Logs API.
#
module SemanticLogger
  module Appender
    class OpenTelemetry < SemanticLogger::Subscriber
      attr_reader :name, :version, :provider, :logger

      CAPTURE_CONTEXT = ->(log) { log.capture(:open_telemetry, ::OpenTelemetry::Context.current) }

      # Create a Open Telemetry Logger appender instance.
      #
      # Parameters
      #   name: [String]
      #     Name of the Open Telemetry logger, which is the instrumentation scope of every log record
      #     it emits.
      #     Default: "SemanticLogger"
      #
      #   version: [String]
      #     Version of that instrumentation scope.
      #     Default: SemanticLogger::VERSION
      #
      # The formatter maps each log entry to an Open Telemetry log record, returning the keyword
      # arguments for `Logger#on_emit` other than `context:`.
      # Default: SemanticLogger::Formatters::OpenTelemetry
      #
      # A metric-only entry, a metric without a message or an exception, is left out, since it is
      # meant for the metric subscribers. To send them as log records with no body, their metric in
      # the attributes, set `metrics: true`.
      #
      # Example
      #    SemanticLogger.add_appender(appender: :open_telemetry)
      def initialize(name: "SemanticLogger",
                     version: SemanticLogger::VERSION,
                     formatter: nil,
                     **args,
                     &)
        # Base#initialize (via Subscriber) overwrites @name with the class name,
        # so call super first and then assign our own attributes.
        super(formatter: formatter, **args, &)

        @name      = name
        @version   = version
        @provider  = ::OpenTelemetry.logger_provider
        @logger    = @provider.logger(name: @name, version: @version)

        # Capture the current Open Telemetry context when a log entry is captured.
        # Prevents duplicate subscribers as long as it is from a constant.
        SemanticLogger.on_log(CAPTURE_CONTEXT)
      end

      # Emits the log record the formatter returns, in the Open Telemetry context captured when the
      # entry was logged, so that the record is correlated with the trace and span active then.
      def log(log)
        context = log.captured(:open_telemetry) || ::OpenTelemetry::Context.current
        @logger.on_emit(**format_log(log), context: context)
        true
      end

      # Flush all pending logs.
      def flush
        return unless @provider

        @provider.force_flush if @provider.respond_to?(:force_flush)
      rescue StandardError => e
        # Swallow to avoid noisy shutdown exceptions.
        SemanticLogger::Processor.logger.warn("Flush failed: #{e.class}: #{e.message}")
      end

      # Close the appender and release resources.
      def close
        return unless @provider

        @provider.shutdown if @provider.respond_to?(:shutdown)
      rescue StandardError => e
        SemanticLogger::Processor.logger.warn("Shutdown failed: #{e.class}: #{e.message}")
      ensure
        @provider = nil
      end

      private

      # Use the Open Telemetry formatter by default: #log emits the log record it returns.
      def default_formatter
        SemanticLogger::Formatters::OpenTelemetry.new
      end
    end
  end
end
