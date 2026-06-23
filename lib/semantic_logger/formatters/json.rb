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
        Utils.to_json(super)
      end

      # Returns a batch of log messages as a single JSON array.
      def batch(logs, logger)
        "[#{logs.map { |log| call(log, logger) }.join(',')}]"
      end
    end
  end
end
