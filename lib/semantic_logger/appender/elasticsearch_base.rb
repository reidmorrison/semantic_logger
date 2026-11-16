require "date"

module SemanticLogger
  module Appender
    # Abstract base appender for Elasticsearch-compatible search engines.
    #
    # Implements the shared bulk-indexing pipeline used by both the
    # {Elasticsearch} and {OpenSearch} appenders. Subclasses only need to
    # supply the backing client class.
    #
    # This class is internal: applications add an appender via
    # `SemanticLogger.add_appender(appender: :elasticsearch, ...)` or
    # `appender: :opensearch`, never by referencing this class directly.
    class ElasticsearchBase < SemanticLogger::Subscriber
      # The most groups of failures that one report of a bulk request lists (see #report_failures).
      MAX_REPORTED_FAILURES = 10
      # The most characters of each reason that the report writes: a reason can repeat a whole value,
      # as the "For input string" of a number that could not be parsed does.
      MAX_REPORTED_REASON = 500
      private_constant :MAX_REPORTED_FAILURES, :MAX_REPORTED_REASON

      attr_accessor :url, :index, :date_pattern, :client, :flush_interval, :timeout_interval, :batch_size,
                    :client_args

      # Create an Elasticsearch-compatible appender over persistent HTTP(S).
      #
      # Parameters:
      #   index: [String]
      #     Prefix of the index to store the logs in.
      #     The final index appends the date so that indexes are used per day.
      #       I.e. The final index will look like 'semantic_logger-YYYY.MM.DD'
      #     Default: 'semantic_logger'
      #
      #   date_pattern: [String]
      #     The time format used to generate the full index name. Useful
      #       if you want monthly indexes ('%Y.%m') or weekly ('%Y.%W').
      #     Default: '%Y.%m.%d'
      #
      #   data_stream: [true|false]
      #     Write to the data stream named by `index:`, with `create` actions,
      #     rather than to a daily index: `date_pattern:` is not used, and the
      #     default formatter writes the time under `@timestamp`.
      #     Default: false
      #
      #   type: [String]
      #     Deprecated and ignored. Document `_type` has been unused since
      #     Elasticsearch 7 and is ignored by OpenSearch. Passing it logs a
      #     deprecation warning; it will be removed in v6.
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: SemanticLogger.default_level
      #
      #   formatter: [Object|Proc|Symbol|Hash]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender. It returns the document, as a Hash, or as a
      #     String of JSON.
      #     Default: :raw, with an ISO 8601 time under `timestamp`, or `@timestamp` with
      #     `data_stream: true`.
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
      #   metrics: [true|false]
      #     Whether to also index metric-only entries: a metric without a message or an exception.
      #     Default: false
      #
      # Client Parameters (passed through to the backing client):
      #   url: [String]
      #     Fully qualified address to the service.
      #     Default: 'http://localhost:9200'
      #
      #   hosts: [String|Hash|Array]
      #     Single host passed as a String or Hash, or multiple hosts
      #     passed as an Array. A Hash takes the keys `host`, `port`,
      #     `scheme`, `user`, `password`, and `path`.
      #     Note:
      #       :url above is ignored when supplying this option.
      #       A `host:` passed to the appender itself, outside the Hash, is
      #       not a server: it is the host name written in each log entry,
      #       see `host:` above.
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
      #   selector
      #     An instance of a connection selector strategy.
      #
      #   send_get_body_as [String]
      #     Specify the HTTP method to use for GET requests with a body.
      #     Default: 'GET'
      def initialize(url: "http://localhost:9200",
                     index: "semantic_logger",
                     date_pattern: "%Y.%m.%d",
                     type: nil,
                     level: nil,
                     formatter: nil,
                     filter: nil,
                     application: nil,
                     environment: nil,
                     host: nil,
                     data_stream: false,
                     metrics: false,
                     **client_args,
                     &)
        if type
          Deprecation.warn(
            "The Elasticsearch/OpenSearch appender `type:` parameter is deprecated and will be removed in v6. " \
            "Document `_type` has been unused since Elasticsearch 7 and is ignored by OpenSearch."
          )
        end

        @url                  = url
        @index                = index
        @date_pattern         = date_pattern
        @client_args          = client_args.dup
        @client_args[:url]    = url if url && !client_args[:hosts]
        @client_args[:logger] = logger
        @data_stream          = data_stream

        super(level: level, formatter: formatter, filter: filter, application: application,
              environment: environment, host: host, metrics: metrics, &)
        reopen
      end

      # The url is left to the client gem to parse, since it also takes a comma separated list of
      # urls, an Array of them, or hosts without a scheme.
      def reopen
        @client = Utils.without_url_in_errors(option: ":url or :hosts") { client_class.new(@client_args) }
      end

      # Log to the index for today, or to the data stream.
      def log(log)
        bulk_write([bulk_index(log), bulk_line(log)])
        true
      end

      def batch(logs)
        messages = []
        logs.each do |log|
          messages << bulk_index(log) << bulk_line(log)
        end

        bulk_write(messages)
        true
      end

      # The whole batch is formatted into a single bulk request before anything is sent.
      def batch_all_or_nothing?
        true
      end

      # The url without its credentials, and the index. See Subscriber#inspect.
      def inspect_details
        url_detail = @client_args.key?(:url) ? "url=#{Utils.redacted_url(url).inspect} " : ""
        "#{url_detail}index=#{index.inspect}"
      end

      private

      # The backing client class, e.g. ::Elasticsearch::Client or ::OpenSearch::Client.
      def client_class
        raise NotImplementedError, "#{self.class} must implement #client_class"
      end

      # Returns [String] the log message formatted as a bulk line, serialized by Utils.to_json
      # and handed to the client as a String. The client gem's serializer writes Infinity and NaN
      # as bare words, which is not JSON, and does not repair invalid UTF-8, a structure nested too
      # deeply, or a Struct (written through its #inspect), so such an entry was dropped or its
      # objects' instance variables were written. Serializing is part of formatting, so an error
      # doing so discards the message rather than stalling the appender (see #format_log). A
      # formatter that returns a String is taken to have serialized the line itself.
      def bulk_line(log)
        format_log(log) { |document| document.is_a?(String) ? document : Utils.to_json(document) }
      end

      # Serializes the action lines; the documents already are (see #bulk_line).
      def bulk_write(messages)
        body        = messages.map { |message| message.is_a?(String) ? message : message.to_json }
        bulk_result =
          if @data_stream
            @client.bulk(index: index, body: body)
          else
            @client.bulk(body: body)
          end

        report_failures(bulk_result["items"]) if bulk_result["errors"]
      end

      # Reports to the internal logger the entries of a bulk request that were not indexed, which
      # are discarded, since sending the request again would index the others twice. The response
      # has an item for each entry, under the name of its action, such as
      # `{"index" => {"_index" => ..., "status" => 400, "error" => {"type" => ..., "reason" => ...}}}`,
      # without the document. An entry failed when its result has an error, or a status of 300 or
      # above: an `index` action succeeds with 201 (created) or 200 (updated), and a `create` action
      # with 201. The failures are grouped by their kind (see #bulk_failure_kind), since the reasons
      # for one kind differ by each entry's id and value, so that a batch whose entries all fail the
      # same way is reported in a short line. Only the first MAX_REPORTED_FAILURES groups are listed.
      def report_failures(items)
        failed = items.map { |item| item.values.first }
        failed.select! { |result| result.key?("error") || result["status"].to_i >= 300 }
        return if failed.empty?

        groups = failed.group_by { |result| bulk_failure_kind(result) }
        listed = groups.first(MAX_REPORTED_FAILURES).map do |kind, results|
          bulk_failure(kind, results.first["error"], results.size)
        end
        others = groups.values.drop(MAX_REPORTED_FAILURES)
        unless others.empty?
          listed << "and #{others.size} other failure#{'s' unless others.size == 1} " \
                    "(#{bulk_entries(others.sum(&:size))})"
        end

        logger.error(
          "#{failed.size} of #{items.size} log entries were not indexed, and are discarded: #{listed.join('; ')}"
        )
      end

      # Returns [Array] the kind of failure of an entry, from the result of its action: its status,
      # error type, and index, and the type of the innermost error that caused it, so that a number
      # and a date that could not be parsed, both a mapping error, are told apart. An error that is a
      # String, as from Elasticsearch 1.x, has no type.
      def bulk_failure_kind(result)
        error = result["error"]
        return [result["status"], nil, result["_index"], nil] unless error.is_a?(Hash)

        [result["status"], error["type"], result["_index"], bulk_causes(error).last&.fetch("type", nil)]
      end

      # Returns [String] a kind of failure of the given number of entries: its status, error type,
      # and index, then the error of the first, as an example when there are others.
      def bulk_failure(kind, error, count)
        status, type, index = kind
        failure = [status, type, "in #{index}"].compact.join(" ")
        failure += " (#{bulk_entries(count)})" if count > 1
        reason = bulk_error_reason(error)
        return failure unless reason

        "#{failure}#{', e.g.' if count > 1}: #{reason}"
      end

      # Returns [String] the reason for an error, followed by each error that caused it, such as the
      # parser's error under a mapping error's "failed to parse", or nil when it has none. An error
      # that is a String is its reason. A cause without a reason is written as its type alone.
      def bulk_error_reason(error)
        return bulk_reason_text(error) unless error.is_a?(Hash)

        reasons = [bulk_reason_text(error["reason"])]
        bulk_causes(error).each do |cause|
          reason = bulk_reason_text(cause["reason"])
          reasons << (reason ? "caused by #{cause['type']}: #{reason}" : "caused by #{cause['type']}")
        end
        reasons.compact!
        reasons.join(", ") unless reasons.empty?
      end

      # Returns [Array<Hash>] the errors that caused this one, from the first to the innermost.
      def bulk_causes(error)
        causes = []
        cause  = error
        causes << cause while (cause = cause["caused_by"]).is_a?(Hash)
        causes
      end

      # Returns [String] a reason as the report writes it, or nil when there is none: its first line
      # only, since the JSON parser adds the error's location on the next, with part of the document;
      # cut to MAX_REPORTED_REASON characters, followed by "..."; and inspected, since it can repeat a
      # value of the entry, so that a control character in that value, such as a line break, cannot
      # forge a line of the log.
      def bulk_reason_text(reason)
        text = reason.to_s.partition("\n").first
        return if text.empty?
        return text.inspect if text.size <= MAX_REPORTED_REASON

        "#{text[0, MAX_REPORTED_REASON].inspect}..."
      end

      # Returns [String] the number of entries, such as "1 entry" or "3 entries".
      def bulk_entries(count)
        count == 1 ? "1 entry" : "#{count} entries"
      end

      def bulk_index(log)
        return {"create" => {}} if @data_stream

        {"index" => {"_index" => log.time.strftime("#{index}-#{date_pattern}")}}
      end

      def default_formatter
        time_key = @data_stream ? "@timestamp" : :timestamp
        SemanticLogger::Formatters::Raw.new(time_format: :iso_8601, time_key: time_key)
      end
    end
  end
end
