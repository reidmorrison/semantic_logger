require 'json'

module SemanticLogger
  module Formatters
    # Fluentd is similar to SemanticLogger::Formatters::Json but with log level that are recongnized
    # by kubernetes fluentd.
    class Fluentd < Json
      attr_reader :need_process_info

      def initialize(log_host: true, log_application: true, need_process_info: false)
        @need_process_info = need_process_info
        super(log_host: log_host, log_application: log_application, time_key: 'time', time_format: :rfc_3339)
      end

      def severity
        hash['severity'] = log.level
        hash['severity_index'] = log.level_index
      end

      def process_info
        # Ignore fields: pid, thread, file and line by default
        super() if need_process_info
      end

      def call(log, logger)
        self.hash   = {}
        self.log    = log
        self.logger = logger

        host; application; time; severity; process_info; duration; tags; named_tags; name; message; payload; exception; metric
        hash

        hash.to_json
      end
    end
  end
end
