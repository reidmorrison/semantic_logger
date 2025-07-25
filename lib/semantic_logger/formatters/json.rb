require "json"
module SemanticLogger
  module Formatters
    class Json < Raw
      # Default JSON time format is ISO8601
      def initialize(time_format: :iso_8601, time_key: :timestamp, **args)
        super
      end

      # Returns log messages in JSON format
      def call(log, logger)
        super.to_json
      end
    end
  end
end
