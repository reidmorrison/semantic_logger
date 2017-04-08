require 'json'
module SemanticLogger
  module Formatters
    class Json < Raw
      # Default JSON time format is ISO8601
      def initialize(time_format: :iso_8601, log_host: true, log_application: true)
        super(time_format: time_format, log_host: log_host, log_application: log_application)
      end

      def time
        hash[:timestamp] = format_time(log.time)
      end

      # Returns log messages in JSON format
      def call(log, logger)
        super(log, logger).to_json
      end

    end
  end
end

