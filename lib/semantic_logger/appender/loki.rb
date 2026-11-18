# Forward log messages to a Grafana Loki instance using its HTTP push API
#
# Example:
#   SemanticLogger.add_appender(
#     appender: :loki,
#     url: "https://logs-prod-001.grafana.net",
#     username: "grafana_username",
#     password: "grafana_token_here",
#     compress: true,
#     formatter: {loki: {structured_metadata: [:pid, :thread]}}
#   )
#
# structured_metadata: needs a Loki that accepts structured metadata (see
# SemanticLogger::Formatters::Loki#initialize).
module SemanticLogger
  module Appender
    class Loki < SemanticLogger::Appender::Http
      INGESTION_PATH = "loki/api/v1/push".freeze

      # Create Grafana Loki appender.
      #
      # Parameters:
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied
      #             regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true.
      #           The Proc must return true or false.
      #
      #   host: [String]
      #     Name of this host to send as a stream label.
      #     Default: SemanticLogger.host
      #
      #   application: [String]
      #     Name of this application to send as a stream label.
      #     Default: SemanticLogger.application
      #
      #   url: [String]
      #     Define the loki instance URL.
      #     Example: https://logs-prod-999.grafana.net
      #     A query string is kept and sent with every request.
      #     Example: https://logs-prod-999.grafana.net?orgid=my_org
      #     Required.
      #
      #   path: [String]
      #     Path of the push API, appended to the path of the url.
      #     Default: 'loki/api/v1/push'
      #
      #   header: [Hash]
      #     HTTP headers to send with every request, such as X-Scope-OrgID, merged over the
      #     headers of the HTTP appender, whose Content-Type is already application/json.
      #     Default: {'Content-Type' => 'application/json'}
      #
      #   formatter: [Object|Proc|Symbol|Hash]
      #     An instance of a class that implements #call and #batch, or a Proc, to be used to
      #     format the output from this appender.
      #     A Hash sets the options of the Loki formatter, such as the labels to write as structured
      #     metadata, or the label limits of a Loki that raises them (see
      #     SemanticLogger::Formatters::Loki#initialize).
      #     Example: {loki: {structured_metadata: [:pid, :thread]}}
      #     Default: SemanticLogger::Formatters::Loki, which reports a deprecation warning without
      #     structured_metadata:, since v6 writes pid and thread as structured metadata by default.
      def initialize(url: nil,
                     formatter: nil,
                     header: {"Content-Type" => "application/json"},
                     path: INGESTION_PATH,
                     **args,
                     &)
        super(url: self.class.ingestion_url(url, path), formatter: formatter, header: header, **args, &)
      end

      # Appends the ingestion path to the supplied url, keeping any query string at the
      # end of the url where Appender::Http can parse it out.
      def self.ingestion_url(url, path)
        uri      = Utils.parse_url(url.to_s)
        uri.path = "#{uri.path.chomp('/')}/#{path.delete_prefix('/')}"
        uri.to_s
      end

      def log(log)
        message = format_log(log)
        logger.trace(message)
        post(message)
      end

      # Logs in batches
      def batch(logs)
        message = format_batch(logs)
        logger.trace(message)
        post(message)
      end

      # The #batch above formats the whole batch with #format_batch, so it answers as
      # Appender::Http#batch_refusal does for its own #batch: only while it is the one in use.
      def batch_refusal
        format_batch_refusal if batch_defined_by?(Loki)
      end

      private

      # Use the Loki formatter by default
      def default_formatter
        SemanticLogger::Formatters::Loki.new
      end
    end
  end
end
