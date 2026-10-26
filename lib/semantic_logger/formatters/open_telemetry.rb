require "json"
module SemanticLogger
  module Formatters
    class OpenTelemetry < Raw
      # primitives allowed by OTLP logs in Ruby: String, Integer, Float, TrueClass, FalseClass
      PRIMS = [String, Integer, Float, TrueClass, FalseClass].freeze

      # Returns the attributes hash submitted to the OpenTelemetry SDK.
      #
      # Unlike the JSON formatters there is no single `.to_json` boundary here:
      # the hash is handed to the OTLP exporter, which requires valid UTF-8. Cleanse
      # the whole structure so binary / non UTF-8 strings cannot break the export.
      def call(log, logger)
        Utils.encode_utf8(super)
      end

      # Log level
      def level
        hash[:level]       = log.level.to_s
        hash[:level_index] = severity_number(log.level)
      end

      # Payload is submitted directly as attributes, which must be a Hash. A log call can supply
      # any value as the payload, such as a String parsed from a request body, so any other value
      # is submitted as a single "payload" attribute.
      def payload
        return unless log.payload?

        hash[:payload] = coerce_map(log.payload.is_a?(Hash) ? log.payload : {payload: log.payload})
      end

      private

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

      def coerce_map(h)
        h.each_with_object({}) do |(k, v), out|
          next if v.nil?

          out[k.to_s] = coerce_value(v)
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
