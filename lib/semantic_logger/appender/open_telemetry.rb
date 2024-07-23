begin
  require "opentelemetry/logs"
rescue LoadError
  raise LoadError, 'Gem opentelemetry-logs-sdk is required for logging to Open Telemetry. Please add the gem "opentelemetry-logs-sdk" to your Gemfile.'
end

# Open Telemetry Appender
#
#   Writes log messages, and metrics to Open Telemetry.
#
module SemanticLogger
  module Appender
    class OpenTelemetry < SemanticLogger::Subscriber
      attr_reader :name, :version, :logger

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
        @name    = name
        @version = version
        @logger  = ::OpenTelemetry.logger_provider.logger(name: @name, version: @version)

        # Capture the current Open Telemetry context when a log entry is captured.
        # Prevents duplicate subscribers as long as it is from a constant.
        SemanticLogger.on_log(CAPTURE_CONTEXT)

        super(formatter: formatter, metrics: metrics, **args, &block)
      end

      def log(log)
        # return log_metric(log) if metrics && log.metric_only?

        ap formatter.call(log, self)
        ap log.payload

        @logger.on_emit(
          severity_text:   log.level.to_s,
          severity_number: severity_number(log.level),
          timestamp:       log.time,
          body:            formatter.call(log, self),
          attributes:      log.payload,
          context:         log.context[:open_telemetry] || ::OpenTelemetry::Context.current
        )
        true
      end

      # Flush all pending logs.
      def flush
        @logger.logger_provider.force_flush
      end

      # Flush pending logs and close the appender
      def close
        @logger.logger_provider.shutdown
      end

      private

      # For logging metrics only log events.
      # def log_metric(log)
      #   puts "**** TODO: Metric Only Event ****"
      #   ap formatter.call(log, self)
      #   ap log.payload
      #   true
      # end

      def severity_number(severity)
        case severity.downcase
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
