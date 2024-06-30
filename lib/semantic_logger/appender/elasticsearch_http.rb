require "date"
# Forward all log messages to Elasticsearch one at a time via a HTTP post.
#
# Note:
# * Other than in very low volume environments it is recommended to rather use the Elasticsearch appender,
#   since it supports bulk logging.
#
# Example:
#   SemanticLogger.add_appender(
#     appender: :elasticsearch_http,
#     url:      'http://localhost:9200'
#   )
module SemanticLogger
  module Appender
    class ElasticsearchHttp < SemanticLogger::Appender::Http
      attr_accessor :index, :type

      # Create Elasticsearch appender over persistent HTTP(S)
      #
      # Parameters:
      #   index: [String]
      #     Prefix of the index to store the logs in Elasticsearch.
      #     The final index appends the date so that indexes are used per day.
      #       I.e. The final index will look like 'semantic_logger-YYYY.MM.DD'
      #     Default: 'semantic_logger'
      #
      #   type: [String]
      #     Document type to associate with logs when they are written.
      #     Deprecated in Elasticsearch 7.0.0
      #     Default: 'log'
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: SemanticLogger.default_level
      #
      #   formatter: [Object|Proc|Symbol|Hash]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: Use the built-in formatter (See: #call)
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      #
      #   host: [String]
      #     Name of this host to appear in log messages.
      #     Default: SemanticLogger.host
      #
      #   application: [String]
      #     Name of this application to appear in log messages.
      #     Default: SemanticLogger.application
      def initialize(index: "semantic_logger",
                     type: "log",
                     url: "http://localhost:9200",
                     **http_args,
                     &block)

        @index = index
        @type  = type
        super(url: url, **http_args, &block)

        @request_path = "#{@path.end_with?('/') ? @path : "#{@path}/"}#{@index}-%Y.%m.%d"
        @logging_path = "#{@request_path}/#{type}"
      end

      # Log to the index for today.
      def log(log)
        post(formatter.call(log, self), log.time.strftime(@logging_path))
      end

      # Deletes all log data captured for a day.
      def delete_all(date = Date.today)
        delete(date.strftime(@request_path))
      end
    end
  end
end
