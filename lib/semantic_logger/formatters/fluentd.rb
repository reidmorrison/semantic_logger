require "json"

module SemanticLogger
  module Formatters
    # Fluentd is similar to SemanticLogger::Formatters::Json but with log levels that are recognized
    # by kubernetes fluentd.
    class Fluentd < Json
      attr_reader :need_process_info

      def initialize(time_format: :rfc_3339, time_key: :time, need_process_info: false, log_host: false, **args)
        @need_process_info = need_process_info
        super(time_format: time_format, time_key: time_key, log_host: log_host, **args)
      end

      def level
        hash["severity"]       = log.level
        hash["severity_index"] = log.level_index
      end

      # Ignore process fields: pid, thread, file and line by default.
      # These are rarely useful under Fluentd (e.g. containerized processes
      # usually have pid 1), so they are only included when explicitly requested
      # via `need_process_info: true`.
      def pid
        super if need_process_info
      end

      def thread_name
        super if need_process_info
      end

      def file_name_and_line
        super if need_process_info
      end
    end
  end
end
