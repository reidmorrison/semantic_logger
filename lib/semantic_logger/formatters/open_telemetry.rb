require "json"
module SemanticLogger
  module Formatters
    class OpenTelemetry < Raw
      # Log level
      def level
        hash[:level]       = log.level.to_s
        hash[:level_index] = severity_number(log.level_index)
      end

      # Payload is submitted directly as attributes
      def payload
        return unless log.payload.respond_to?(:empty?) && !log.payload.empty?

        hash[:payload] = log.payload.transform_keys!(&:to_s)
      end

      private

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
