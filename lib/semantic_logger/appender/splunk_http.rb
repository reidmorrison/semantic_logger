require "json"
# Splunk log appender using the Splunk HTTP(S) listener.
#
# Use the newer, faster and more complete JSON over HTTP interface for Splunk.
#
# To configure Splunk to receive log messages via this appender:
#   http://dev.splunk.com/view/event-collector/SP-CAAAE7F
#
# Example
#   SemanticLogger.add_appender(
#     appender: :splunk_http,
#     url:      'http://localhost:8080',
#     token:    '70CA900C-3D7E-42A4-9C79-7975D1C422A8'
#   )
#
# Batching:
# Add it with `batch: true` to send many entries in each request, as event objects stacked one after
# the other, each one what the appender sends for that entry on its own (see #batch).
#
# Responses:
# The HTTP Event Collector answers 400 Bad Request both for the entries a request holds, and for its
# own configuration, such as an index it does not know. Its JSON body says which, with a numeric
# `code` and a `text`. A batch it rejects for its configuration is discarded at once, rather than
# split up to find the entries at fault, since every part would be rejected too (see
# #fails_any_batch?). For a batch it rejects at one of its events, it says which one, having indexed
# those before it (see #rejected_entry).
module SemanticLogger
  module Appender
    class SplunkHttp < SemanticLogger::Appender::Http
      # The status codes in the body of a 400 Bad Request from the HTTP Event Collector that reject
      # the request for the collector's configuration or the appender's, whatever entries it holds:
      #    7 Incorrect index
      #   10 Data channel is missing
      #   11 Invalid data channel
      #   14 ACK is disabled
      #   16 Query string authorization is not enabled
      #   21 Invalid token
      #   22 Token disabled
      # The others it answers with a 400 are caused by the entries, so a batch is split up to find
      # them: 5 No data, 6 Invalid data format, 12 Event field is required, 13 Event field cannot be
      # blank, and 15 Error in handling indexed fields.
      #
      # See "Troubleshoot HTTP Event Collector", Possible error codes:
      #   https://help.splunk.com/en/splunk-enterprise/get-started/get-data-in/10.4/get-data-with-http-event-collector/troubleshoot-http-event-collector
      CONFIGURATION_CODES = [7, 10, 11, 14, 16, 21, 22].freeze

      attr_accessor :source_type, :index

      # Create Splunk appender over persistent HTTP(S)
      #
      # Parameters:
      #   token: [String]
      #     Token created in Splunk for this HTTP Appender
      #     Mandatory.
      #
      #   source_type: [String]
      #     Optional: Source type to display in Splunk
      #
      #   index: [String]
      #     Optional: Name of a valid index for this message in Splunk.
      #
      #   url: [String]
      #     Valid URL to post to.
      #       Example: http://example.com
      #     To enable SSL include https in the URL.
      #       Example: https://example.com
      #       verify_mode will default: OpenSSL::SSL::VERIFY_PEER
      #
      #   application: [String]
      #     Name of this application to appear in log messages.
      #     Default: SemanticLogger.application
      #
      #   host: [String]
      #     Name of this host to appear in log messages.
      #     Default: SemanticLogger.host
      #
      #   compress: [true|false]
      #     Splunk supports HTTP Compression, enable by default.
      #     Default: true
      #
      #   ssl: [Hash]
      #     Specific SSL options: For more details see NET::HTTP.start
      #       ca_file, ca_path, cert, cert_store, ciphers, key, open_timeout, read_timeout, ssl_timeout,
      #       ssl_version, use_ssl, verify_callback, verify_depth and verify_mode.
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: none (:trace), so it writes every entry that a logger emits; each logger
      #     filters by its own level.
      #
      #   formatter: [Object|Proc]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: Use the built-in formatter (See: #call)
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      def initialize(token: nil,
                     source_type: nil,
                     index: nil,
                     compress: true,
                     **args,
                     &)
        @source_type = source_type
        @index       = index

        super(compress: compress, **args, &)

        # Put splunk auth token in the header of every HTTP post.
        replace_header("Authorization", "Splunk #{token}")
      end

      # Returns [String] JSON to send to Splunk.
      #
      # For splunk format requirements see:
      #   https://docs.splunk.com/Documentation/Splunk/latest/Data/FormateventsforHTTPEventCollector
      def call(log, logger)
        h = SemanticLogger::Formatters::Raw.new(time_format: :seconds).call(log, logger)
        h.delete(:host)
        message = {
          source: logger.application,
          host:   logger.host,
          time:   h.delete(:time),
          event:  h
        }
        message[:sourcetype]  = source_type if source_type
        message[:index]       = index if index
        Utils.to_json(message)
      end

      # Whether the exception would fail any batch, whatever entries it holds (see
      # Http#fails_any_batch?), including a 400 Bad Request whose body holds one of the collector's
      # CONFIGURATION_CODES, such as for a wrong `index:`. So the batch is discarded at once, and
      # reported once, with the collector's text, rather than split up and each entry sent on its own.
      def fails_any_batch?(exception)
        super || (exception.is_a?(ResponseError) && exception.rejected? &&
          CONFIGURATION_CODES.include?(collector_response(exception.body)["code"]))
      end

      # Send a batch of log messages to the HTTP Event Collector in a single request, as event objects
      # stacked one after the other, the batch format of "Format events for HTTP Event Collector":
      #   https://help.splunk.com/en/splunk-enterprise/get-started/get-data-in/10.6/get-data-with-http-event-collector/format-events-for-http-event-collector
      #
      # Each event is what #log sends for that entry, formatted by #format_log. The formatter must
      # format each entry as exactly one event object, as the default one, the appender itself (see
      # #call), does, since the collector names a rejected event by its position in the request (see
      # #rejected_entry).
      # Every entry is formatted before the request is sent, so a format error sends nothing, and the
      # batch is split up to find the entry at fault (see Http#batch_all_or_nothing?).
      def batch(logs)
        message = logs.map { |log| format_log(log) }.join
        logger.trace(message)
        post(message)
      end

      # Returns [Integer|nil] the position in the batch of the event that the HTTP Event Collector
      # rejected, from the `invalid-event-number` in the body of its 400 Bad Request, such as
      # {"text":"Invalid data format","code":6,"invalid-event-number":2}, or nil when it holds none
      # (see Subscriber#rejected_entry).
      #
      # The collector reads the events of a batch in order, and indexes those before the one it
      # rejects. Splunk's documentation does not say so: "Troubleshoot HTTP Event Collector" and
      # "Format events for HTTP Event Collector" describe neither `invalid-event-number` nor what
      # happens to the rest of a batch. Users report it, for example
      # https://github.com/moby/moby/issues/35862, where a batch of 10 whose last event is malformed,
      # sent again and again, had "the first 1-9 ... accepted by Splunk over and over again".
      #
      # So splitting such a batch to find the event at fault would index the events before it twice.
      # Instead the events before it are counted as written, it is discarded, and those after it,
      # which the collector never read, are sent again. A 400 without the number, such as a proxy's,
      # is split as for Http, and so is any other status, which the collector does not answer with an
      # event number. The number counts events, so a formatter must format each entry as one event
      # object, as the default one does.
      def rejected_entry(exception)
        return unless exception.is_a?(ResponseError) && exception.code == 400

        collector_response(exception.body)["invalid-event-number"]
      end

      private

      # Returns [Hash] the body of a response from the HTTP Event Collector, such as
      # {"text":"Incorrect index","code":7}, or an empty Hash for a body that is not a JSON object,
      # such as a response from a proxy in front of it.
      def collector_response(body)
        parsed = JSON.parse(body.to_s)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end
    end
  end
end
