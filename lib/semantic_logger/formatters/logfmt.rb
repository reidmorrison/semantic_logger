require "json"

module SemanticLogger
  module Formatters
    class Logfmt < Raw
      def initialize(time_format: :iso_8601, time_key: :timestamp, **args)
        super(time_format: time_format, time_key: time_key, **args)
      end

      def call(log, logger)
        @raw = super(log, logger)

        raw_to_logfmt
      end

      private

      def raw_to_logfmt
        @parsed = @raw.slice(:timestamp, :level, :name, :message, :duration).merge tag: "success"
        handle_payload
        handle_exception

        flatten_log
      end

      def handle_payload
        return unless @raw.key? :payload

        @parsed = @parsed.merge(@raw[:payload])
      end

      def handle_exception
        return unless @raw.key? :exception

        @parsed[:tag] = "exception"
        @parsed = @parsed.merge(@raw[:exception])
      end

      def flatten_log
        flattened = @parsed.map do |key, value|
          "#{key}=#{parse_value(value)}"
        end

        flattened.join(" ")
      end

      def parse_value(value)
        return value.to_json if value.instance_of? String

        value
      end
    end
  end
end
