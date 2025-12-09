begin
  require "opentelemetry/logs"
rescue LoadError
  raise LoadError,
        'Gem opentelemetry-logs-sdk is required for logging to Open Telemetry. Please add the gem "opentelemetry-logs-sdk" to your Gemfile.'
end

# Open Telemetry Appender
#
#   Writes log messages, and metrics to Open Telemetry.
#
module SemanticLogger
  module Appender
    class OpenTelemetry < SemanticLogger::Subscriber
      attr_reader :name, :version, :provider, :logger

      CAPTURE_CONTEXT = ->(log) { log.set_context(:open_telemetry, ::OpenTelemetry::Context.current) }

      # Create a Open Telemetry Logger appender instance.
      #
      # Metric only log events are sent to the Open Telemetry Metrics API instead of the Logs API.
      #   I.e. A metric without a message or an exception.
      #   To disable this default behavior set `metrics: false`
      #
      # Example
      #    SemanticLogger.add_appender(appender: :open_telemetry)
      def initialize(name: "SemanticLogger",
                     version: SemanticLogger::VERSION,
                     formatter: SemanticLogger::Formatters::OpenTelemetry.new,
                     metrics: true,
                     **args,
                     &block)
        @name      = name
        @version   = version
        @provider  = ::OpenTelemetry.logger_provider
        @logger    = @provider.logger(name: @name, version: @version)

        # Capture the current Open Telemetry context when a log entry is captured.
        # Prevents duplicate subscribers as long as it is from a constant.
        SemanticLogger.on_log(CAPTURE_CONTEXT)

        super(formatter: formatter, metrics: metrics, **args, &block)
      end

      def log(log)
        # return log_metric(log) if metrics && log.metric_only?

        body        = formatter.call(log, self)
        level       = body.delete(:level)
        level_index = body.delete(:level_index)
        time        = body.delete(:time)
        payload     = body.delete(:payload)

        @logger.on_emit(
          severity_text:   level,
          severity_number: level_index,
          timestamp:       time,
          body:            body.transform_keys!(&:to_s),
          attributes:      payload,
          context:         log.context[:open_telemetry] || ::OpenTelemetry::Context.current
        )
        true
      end

      # Flush all pending logs.
      def flush
        return unless @provider

        @provider.force_flush if @provider.respond_to?(:force_flush)
      rescue StandardError => e
        # Swallow to avoid noisy shutdown exceptions.
        SemanticLogger.logger.warn("Flush failed: #{e.class}: #{e.message}")
      end

      # Close the appender and release resources.
      def close
        return unless @provider

        @provider.shutdown if @provider.respond_to?(:shutdown)
      rescue StandardError => e
        SemanticLogger.logger.warn("Shutdown failed: #{e.class}: #{e.message}")
      ensure
        @provider = nil
      end

      # For logging metrics only log events.
      # def log_metric(log)
      #   puts "**** TODO: Metric Only Event ****"
      #   ap formatter.call(log, self)
      #   ap log.payload
      #   true
      # end
    end
  end
end
