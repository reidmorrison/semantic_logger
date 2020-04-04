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

        def initialize(trace: GELF::DEBUG, debug: GELF::DEBUG, info: GELF::INFO, warn: GELF::WARN, error: GELF::ERROR, fatal: GELF::FATAL)
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
                     &block)

        @url          = url
        @max_size     = max_size
        @gelf_options = gelf_options
        @level_map    = level_map.is_a?(LevelMap) ? level_map : LevelMap.new(level_map)

        super(**args, &block)
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

        h[:short_message] = h.delete(:message)
        if h[:short_message].nil?
          h[:short_message] = log.exception.nil? ? "<no-exception-message>" : log.exception.message
        end
        h[:level]        = logger.level_map[log.level]
        h[:level_str]    = log.level.to_s
        h[:duration_str] = h.delete(:duration)
        h
      end

      # Forward log messages
      def log(log)
        notifier.notify!(formatter.call(log, self))
        true
      end

      private

      def default_formatter
        SemanticLogger::Formatters::Raw.new(time_format: :seconds, time_key: :timestamp)
      end
    end
  end
end
