require 'json'
module SemanticLogger
  module Formatters
    class Json < Raw
      # Default JSON time format is ISO8601
      def initialize(time_format: :iso_8601, log_host: true, log_application: true)
        super(time_format: time_format, log_host: log_host, log_application: log_application)
      end

      # Returns log messages in JSON format
      def call(log, logger)
        h = super(log, logger)
        h.delete(:time)
        h[:timestamp] = format_time(log.time)
         # host names may contain non UTF-8 characters
         # that will cause JSON serialization to fail
        h[:host] = h[:host].force_encoding('UTF-8')
        h.to_json
      end

    end
  end
end

