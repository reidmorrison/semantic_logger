require "json"
module SemanticLogger
  module Formatters
    class Json < Raw
      # Default JSON time format is ISO8601
      def initialize(time_format: :iso_8601, time_key: :timestamp, **args)
        super(time_format: time_format, time_key: time_key, **args)
      end

      # Returns log messages in JSON format
      def call(log, logger)
        super(log, logger).to_json
      end
    end
  end
end
