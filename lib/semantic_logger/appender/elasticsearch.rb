begin
  require "elasticsearch"
rescue LoadError
  raise LoadError,
        'Gem elasticsearch is required for logging to Elasticsearch. Please add the gem "elasticsearch" to your Gemfile.'
end

require "date"

# Forward all log messages to Elasticsearch.
#
# Example:
#
#   SemanticLogger.add_appender(
#     appender: :elasticsearch,
#     url:      'http://localhost:9200'
#   )
module SemanticLogger
  module Appender
    class Elasticsearch < SemanticLogger::Subscriber
      attr_accessor :url, :index, :date_pattern, :type, :client, :flush_interval, :timeout_interval, :batch_size,
                    :elasticsearch_args

      # Create Elasticsearch appender over persistent HTTP(S)
      #
      # Parameters:
      #   index: [String]
      #     Prefix of the index to store the logs in Elasticsearch.
      #     The final index appends the date so that indexes are used per day.
      #       I.e. The final index will look like 'semantic_logger-YYYY.MM.DD'
      #     Default: 'semantic_logger'
      #
      #   date_pattern: [String]
      #     The time format used to generate the full index name. Useful
      #       if you want monthly indexes ('%Y.%m') or weekly ('%Y.%W').
      #     Default: '%Y.%m.%d'
      #
      #   type: [String]
      #     Document type to associate with logs when they are written.
      #     Deprecated in Elasticsearch 7.0.0.
      #     Default: 'log'
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: SemanticLogger.default_level
      #
      #   formatter: [Object|Proc|Symbol|Hash]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: :raw_json (See: #call)
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
      #
      # Elasticsearch Parameters:
      #   url: [String]
      #     Fully qualified address to the Elasticsearch service.
      #     Default: 'http://localhost:9200'
      #
      #   hosts: [String|Hash|Array]
      #     Single host passed as a String or Hash, or multiple hosts
      #     passed as an Array; `host` or `url` keys are also valid.
      #     Note:
      #       :url above is ignored when supplying this option.
      #
      #   resurrect_after [Float]
      #     After how many seconds a dead connection should be tried again.
      #
      #   reload_connections [true|false|Integer]
      #     Reload connections after X requests.
      #     Default: false
      #
      #   randomize_hosts [true|false]
      #     Shuffle connections on initialization and reload.
      #     Default: false
      #
      #   sniffer_timeout [Integer]
      #     Timeout for reloading connections in seconds.
      #     Default: 1
      #
      #   retry_on_failure [true|false|Integer]
      #     Retry X times when request fails before raising and exception.
      #     Default: false
      #
      #   retry_on_status [Array<Number>]
      #     Retry when specific status codes are returned.
      #
      #   reload_on_failure [true|false]
      #     Reload connections after failure.
      #     Default: false
      #
      #   request_timeout [Integer]
      #     The request timeout to be passed to transport in options.
      #
      #   adapter [Symbol]
      #     A specific adapter for Faraday (e.g. `:patron`)
      #
      #   transport_options [Hash]
      #     Options to be passed to the `Faraday::Connection` constructor.
      #
      #   transport_class [Constant]
      #     A specific transport class to use, will be initialized by
      #     the client and passed hosts and all arguments.
      #
      #   transport [Object]
      #     A specific transport instance.
      #
      #   serializer_class [Constant]
      #     A specific serializer class to use, will be initialized by
      #     the transport and passed the transport instance.
      #
      #   selector [Elasticsearch::Transport::Transport::Connections::Selector::Base]
      #     An instance of selector strategy derived from `Elasticsearch::Transport::Transport::Connections::Selector::Base`.
      #
      #   send_get_body_as [String]
      #     Specify the HTTP method to use for GET requests with a body.
      #     Default: 'GET'
      def initialize(url: "http://localhost:9200",
                     index: "semantic_logger",
                     date_pattern: "%Y.%m.%d",
                     type: "log",
                     level: nil,
                     formatter: nil,
                     filter: nil,
                     application: nil,
                     environment: nil,
                     host: nil,
                     data_stream: false,
                     **elasticsearch_args,
                     &block)

        @url                         = url
        @index                       = index
        @date_pattern                = date_pattern
        @type                        = type
        @elasticsearch_args          = elasticsearch_args.dup
        @elasticsearch_args[:url]    = url if url && !elasticsearch_args[:hosts]
        @elasticsearch_args[:logger] = logger
        @data_stream                 = data_stream

        super(level: level, formatter: formatter, filter: filter, application: application, environment: environment, host: host, metrics: false, &block)
        reopen
      end

      def reopen
        @client = ::Elasticsearch::Client.new(@elasticsearch_args)
      end

      # Log to the index for today
      def log(log)
        bulk_payload = formatter.call(log, self)
        write_to_elasticsearch([bulk_index(log), bulk_payload])
        true
      end

      def batch(logs)
        messages = []
        logs.each do |log|
          messages << bulk_index(log) << formatter.call(log, self)
        end

        write_to_elasticsearch(messages)
        true
      end

      private

      def write_to_elasticsearch(messages)
        bulk_result =
          if @data_stream
            @client.bulk(index: index, body: messages)
          else
            @client.bulk(body: messages)
          end

        return unless bulk_result["errors"]

        failed = bulk_result["items"].reject { |x| x["status"] == 201 }
        logger.error("ElasticSearch: Write failed. Messages discarded. : #{failed}")
      end

      def bulk_index(log)
        expanded_index_name = log.time.strftime("#{index}-#{date_pattern}")
        return {"create" => {}} if @data_stream

        bulk_index = {"index" => {"_index" => expanded_index_name}}
        bulk_index["index"].merge!({"_type" => type}) if version_supports_type?
        bulk_index
      end

      def default_formatter
        time_key = @data_stream ? "@timestamp" : :timestamp
        SemanticLogger::Formatters::Raw.new(time_format: :iso_8601, time_key: time_key)
      end

      def version_supports_type?
        Gem::Version.new(::Elasticsearch::VERSION) < Gem::Version.new(7)
      end
    end
  end
end
