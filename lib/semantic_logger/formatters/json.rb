require 'json'
module SemanticLogger
  module Formatters
    class Json < Raw
      # Default JSON time format is ISO8601
      def initialize(options = {})
        options               = options.dup
        options[:time_format] = :iso_8601 unless options.has_key?(:time_format)
        super(options)
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

