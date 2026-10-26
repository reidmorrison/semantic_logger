require "uri"
begin
  require "gelf"
rescue LoadError
  raise LoadError, 'Gem gelf is required for logging to Graylog. Please add the gem "gelf" to your Gemfile.'
end

# Forward log entries to a Graylog server.
#
# Example:
#   SemanticLogger.add_appender(
#     appender: :graylog,
#     url:      'udp://localhost:12201'
#   )
#
# Notes:
# * trace is not supported by Graylog, so trace level logging will appear as debug in Graylog.
#
# In the Graylog Web UI search screen, it is recommended to include the following fields:
#  `duration`, `level`, `message`, `metric`, `name`, `tags
module SemanticLogger
  module Appender
    class Graylog < SemanticLogger::Subscriber
      # Map Semantic Logger levels to Graylog levels
      class LevelMap
        attr_accessor :trace, :debug, :info, :warn, :error, :fatal

        def initialize(trace: GELF::DEBUG, debug: GELF::DEBUG, info: GELF::INFO, warn: GELF::WARN, error: GELF::ERROR,
                       fatal: GELF::FATAL)
          @trace = trace
          @debug = debug
          @info  = info
          @warn  = warn
          @error = error
          @fatal = fatal
        end

        def [](level)
          public_send(level)
        end
      end

      attr_accessor :url, :max_size, :gelf_options, :level_map
      attr_reader :notifier, :server, :port, :protocol

      # Create Graylog log appender.
      #
      # Options:
      #   url: [String]
      #     Valid URL to post to.
      #     Log to UDP Example:
      #       'udp://localhost:12201'
      #     Log to TCP Example:
      #       'tcp://localhost:12201'
      #     Default: 'udp://localhost:12201'
      #
      #   max_size: [String]
      #     Max udp packet size. Ignored when protocol is :tcp
      #     Default: "WAN"
      #
      #   gelf_options: [Hash]
      #     Custom gelf options. See Graylog documentation.
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: SemanticLogger.default_level
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
      #
      #   host: [String]
      #     Name of this host to appear in log messages.
      #     Default: SemanticLogger.host
      #
      #   application: [String]
      #     Name of this application to appear in log messages.
      #     Default: SemanticLogger.application
      def initialize(url: "udp://localhost:12201",
                     max_size: "WAN",
                     gelf_options: {},
                     level_map: LevelMap.new,
                     **args,
                     &)
        @url          = url
        @max_size     = max_size
        @gelf_options = gelf_options
        @level_map    = level_map.is_a?(LevelMap) ? level_map : LevelMap.new(level_map)

        super(**args, &)
        reopen
      end

      # Re-open after process fork
      def reopen
        uri       = URI.parse(@url)
        @server   = uri.host
        @port     = uri.port
        @protocol = uri.scheme.to_sym

        unless %i[udp tcp].include?(@protocol)
          raise(ArgumentError, "Invalid protocol value: #{@protocol}. Must be :udp or :tcp")
        end

        gelf_options[:protocol] ||= (@protocol == :tcp ? GELF::Protocol::TCP : GELF::Protocol::UDP)
        gelf_options[:facility] ||= application

        @notifier                       = GELF::Notifier.new(server, port, max_size, gelf_options)
        @notifier.collect_file_and_line = false
      end

      # Returns [Hash] of parameters to send
      def call(log, logger)
        h = default_formatter.call(log, logger)

        # GELF rejects an empty short_message, such as a message of only ANSI escape codes.
        h[:short_message] = h.delete(:message).to_s
        h[:short_message] = log.exception.message.to_s.strip if h[:short_message].empty? && log.exception
        h[:short_message] = "<no-exception-message>" if h[:short_message].empty?
        h[:level]        = logger.level_map[log.level]
        h[:level_str]    = log.level.to_s
        h[:duration_str] = h.delete(:duration)
        h
      end

      # Forward log messages
      #
      # GELF serializes the Hash with #to_json, which raises for Infinity, NaN, invalid UTF-8, or a
      # structure nested too deeply, and writes a Struct through its #inspect, so it is handed a
      # copy that JSON can represent (see Utils.json_safe).
      def log(log)
        notifier.notify!(Utils.json_safe(format_log(log)))
        true
      end

      # GELF raises ArgumentError for a log message it cannot send, such as one too large to fit in
      # the maximum number of chunks, which retrying cannot send either. Unavailable servers raise
      # network errors instead.
      def message_error?(exception)
        exception.is_a?(ArgumentError) || super
      end

      private

      def default_formatter
        SemanticLogger::Formatters::Raw.new(time_format: :seconds, time_key: :timestamp)
      end
    end
  end
end
