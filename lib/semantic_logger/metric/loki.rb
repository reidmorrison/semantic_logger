# Forward application metrics to a Loki instance using HTTP.
#
# Example:
#   SemanticLogger.add_appender(
#     metric: :loki,
#     url: "https://logs-prod-001.grafana.net"
#   )
module SemanticLogger
  module Metric
    class Loki < SemanticLogger::Appender::Http
      INGESTION_PATH = "loki/api/v1/push".freeze

      # Create Loki metrics appender.
      #
      # Parameters:
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied
      #             regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true.
      #           The Proc must return true or false.
      #
      #   host: [String]
      #     Name of this host to send as a dimension.
      #     Default: SemanticLogger.host
      #
      #   application: [String]
      #     Name of this application to send as a dimension.
      #     Default: SemanticLogger.application
      #
      #   url: [String]
      #     Define the loki instance URL.
      #     Example: https://logs-prod-999.grafana.net
      #     Default: nil
      def initialize(url: nil,
                     formatter: SemanticLogger::Formatters::Loki.new,
                     header: {"Content-Type" => "application/json"},
                     path: INGESTION_PATH,
                     **args,
                     &block)

        super(url: "#{url}/#{path}", formatter: formatter, header: header, **args, &block)
      end

      def log(log)
        message = formatter.call(log, self)
        puts message
        logger.trace(message)
        post(message)
      end

      # Logs in batches
      def batch(logs)
        message = formatter.batch(logs, self)
        logger.trace(message)
        post(message)
      end
    end
  end
end
