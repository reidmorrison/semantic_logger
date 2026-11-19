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
# Responses:
# The HTTP Event Collector answers 400 Bad Request both for the entries a request holds, and for its
# own configuration, such as an index it does not know. Its JSON body says which, with a numeric
# `code` and a `text`. A batch it rejects for its configuration is discarded at once, rather than
# split up to find the entries at fault, since every part would be rejected too (see
# #fails_any_batch?).
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
        @header["Authorization"] = "Splunk #{token}"
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
          CONFIGURATION_CODES.include?(collector_code(exception.body)))
      end

      private

      # Returns [Integer|nil] the status code in the body of a response from the HTTP Event
      # Collector, such as {"text":"Incorrect index","code":7}, or nil when it holds none, such as a
      # response from a proxy in front of it.
      def collector_code(body)
        parsed = JSON.parse(body.to_s)
        parsed["code"] if parsed.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
