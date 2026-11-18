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
      #
      # Builds a new notifier, which connects to the server over TCP, and then closes the connections of
      # the notifier it replaces, such as after a log rotation. When connecting fails, it raises, and
      # keeps the notifier it has.
      #
      # A child process first forgets the notifier it inherited, without closing it: over TCP, its
      # connection belongs to the parent. So when connecting fails in the child, such as while the server
      # cannot be reached, the appender connects again on its next write, rather than writing through the
      # parent's connection. Over TLS, both processes would then carry on the same TLS session, so that
      # the server could not decrypt what the parent writes next. Ruby closes the child's copy of the
      # socket when it collects the notifier. GELF keeps its sockets to itself, so until then the child
      # holds that copy open, and over plain TCP the server does not see the connection end when the
      # parent closes it.
      def reopen
        forget_inherited

        uri       = Utils.parse_url(@url)
        @server   = uri.host
        @port     = uri.port
        @protocol = uri.scheme.to_sym

        unless %i[udp tcp].include?(@protocol)
          raise(ArgumentError, "Invalid protocol value: #{@protocol}. Must be :udp or :tcp")
        end

        replaced = @notifier
        build_notifier
        close_notifier(replaced, replaced: true)
      end

      # Closes the notifier's TCP connections, such as when the appender is removed, and forgets it, so
      # that the next write builds a new one. An error closing them is reported to the internal logger,
      # rather than raised.
      #
      # In a forked child that has not reopened, such as one that removes the appender before its reopen
      # has run, it forgets the notifier it inherited instead, without closing it: over TCP, its
      # connection belongs to the parent (see #reopen).
      def close
        forget_inherited
        close_notifier(@notifier)
      ensure
        @notifier = nil
      end

      # Returns [Hash] of parameters to send
      def call(log, logger)
        h = default_formatter.call(log, logger)

        # GELF rejects an empty short_message, such as a message of only ANSI escape codes.
        h[:short_message] = h.delete(:message).to_s
        h[:short_message] = short_message_of(log.exception) if h[:short_message].empty? && log.exception
        h[:short_message] = "<no-exception-message>" if h[:short_message].empty?
        h[:level]        = logger.level_map[log.level]
        h[:level_str]    = log.level.to_s
        h[:duration_str] = h.delete(:duration)
        h
      end

      # Forward log messages
      #
      # GELF serializes the Hash with #to_json, which raises for Infinity, NaN, invalid UTF-8, or a
      # structure nested too deeply, and writes a Struct through its #inspect, so such a Hash is
      # handed over as a copy that JSON can represent (see Utils.json_ready).
      #
      # Builds a notifier first when the appender has none: after #close, or when building one failed as
      # it was reopened after a fork.
      def log(log)
        (notifier || build_notifier).notify!(format_log(log) { |hash| Utils.json_ready(hash) })
        true
      end

      # GELF raises ArgumentError for a log message it cannot send, such as one too large to fit in
      # the maximum number of chunks, which retrying cannot send either. Unavailable servers raise
      # network errors instead.
      def message_error?(exception)
        exception.is_a?(ArgumentError) || super
      end

      # The url without any credentials. See Subscriber#inspect.
      def inspect_details
        "url=#{Utils.redacted_url(url).inspect}"
      end

      private

      # Returns [GELF::Notifier] a new notifier, which connects to the server over TCP, after making it
      # the appender's. Records the process that built it, which owns its connection (see #reopen).
      def build_notifier
        @notifier                       = GELF::Notifier.new(server, port, max_size, notifier_options)
        @notifier.collect_file_and_line = false
        @pid                            = ::Process.pid
        @notifier
      end

      # In a child process, forgets the notifier built in the parent before a fork. See #reopen.
      def forget_inherited
        @notifier = nil unless @pid == ::Process.pid
      end

      # Closes the TCP connections of the given notifier, if any: the one that a reopen replaced, when
      # replaced: is true. Reports an error to the internal logger as a warning, rather than raising it.
      #
      # GELF::Notifier#close cannot: over TCP it raises NoMethodError, since GELF's TCP transport has no
      # #close, and over UDP it closes the socket that GELF shares among every UDP notifier that sends on
      # the calling thread, where the next one to send fails with IOError. Giving the notifier no address
      # to send to closes the sockets of its TCP transport, and leaves that UDP socket open.
      def close_notifier(notifier, replaced: false)
        notifier&.addresses = []
      rescue StandardError => e
        logger.warn("Could not close the connection to the Graylog server#{' that a reopen replaced' if replaced}", e)
      end

      # Returns [Hash] a copy of the gelf_options (see Subscriber#copy_options), with the protocol of the url
      # and the application as the facility, unless they name their own, for a new GELF::Notifier.
      def notifier_options
        options = copy_options(gelf_options)
        options[:protocol] ||= (@protocol == :tcp ? GELF::Protocol::TCP : GELF::Protocol::UDP)
        options[:facility] ||= application
        options
      end

      def default_formatter
        SemanticLogger::Formatters::Raw.new(time_format: :seconds, time_key: :timestamp)
      end

      # Returns [String] the exception's message, without the whitespace around it, for an entry
      # without a message. Read with Utils.exception_message, so that a #message that raises cannot
      # lose the entry, and converted to valid UTF-8 first, since #strip raises for invalid bytes.
      def short_message_of(exception)
        Utils.encode_utf8_string(Utils.exception_message(exception)).strip
      end
    end
  end
end
