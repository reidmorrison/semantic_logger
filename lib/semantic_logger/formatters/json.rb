require 'json'
module SemanticLogger
  module Formatters
    class Json
      # Returns log messages in JSON format
      def call(log, logger)
        h = log.to_h
        h.delete(:time)
        h[:timestamp] = log.time.utc.iso8601(defined?(JRuby) ? 3 : 6)
        h.to_json
      end

    end
  end
end

