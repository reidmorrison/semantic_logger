require "json"

module SemanticLogger
  module Formatters
    # Fluentd is similar to SemanticLogger::Formatters::Json but with log levels that are recognized
    # by kubernetes fluentd.
    class Fluentd < Json
      attr_reader :need_process_info

      def initialize(time_format: :rfc_3339, time_key: :time, need_process_info: false, **args)
        @need_process_info = need_process_info
        super(time_format: time_format, time_key: time_key, **args)
      end

      def level
        hash["severity"]       = log.level
        hash["severity_index"] = log.level_index
      end

      def process_info
        # Ignore fields: pid, thread, file and line by default
        super() if need_process_info
      end
    end
  end
end
