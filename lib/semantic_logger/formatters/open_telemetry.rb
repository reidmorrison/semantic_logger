require "json"
module SemanticLogger
  module Formatters
    class OpenTelemetry < Raw
      # primitives allowed by OTLP logs in Ruby: String, Integer, Float, TrueClass, FalseClass
      PRIMS = [String, Integer, Float, TrueClass, FalseClass].freeze

      # Log level
      def level
        hash[:level]       = log.level.to_s
        hash[:level_index] = severity_number(log.level_index)
      end

      # Payload is submitted directly as attributes
      def payload
        return unless log.payload.respond_to?(:empty?) && !log.payload.empty?

        hash[:payload] = coerce_map(log.payload)
      end

      private

      def coerce_value(v)
        case v
        when *PRIMS then v
        when Array  then v.map { |e| coerce_value(e) }.compact   # arrays of scalars only.
        when NilClass then nil                                   # drop nils by caller.
        else v.to_s                                              # stringify objects / hashes.
        end
      end

      def coerce_map(h)
        h.each_with_object({}) do |(k, v), out|
          next if v.nil?

          out[k.to_s] =
            if v.is_a?(Hash)
              # Stringify whole hash.
              v.transform_values { |vv| coerce_value(vv) }.
                transform_keys!(&:to_s).
                to_json
            else
              coerce_value(v)
            end
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
