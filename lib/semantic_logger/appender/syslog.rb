require "uri"
require "socket"
# Send log messages to local syslog, or remote syslog servers over TCP or UDP.
#
# Example:
#   # Log to a local Syslog daemon
#   SemanticLogger.add_appender(appender: :syslog)
#
# Example:
#   # Log to a remote Syslog server over TCP:
#   SemanticLogger.add_appender(
#     appender: :syslog,
#     url:      'tcp://myloghost:514'
#   )
#
# Example:
#   # Log to a remote Syslog server over UDP:
#   SemanticLogger.add_appender(
#     appender: :syslog,
#     url:      'udp://myloghost:514'
#   )
#
# Example:
#   # Log to a remote Syslog server using the CEE format over TCP:
#   SemanticLogger.add_appender(
#     appender: :syslog,
#     url:      'tcp://myloghost:514'
#   )
#
module SemanticLogger
  module Appender
    class Syslog < SemanticLogger::Subscriber
      attr_reader :remote_syslog, :url, :server, :port, :protocol, :facility, :options, :level_map, :max_size

      # Create a Syslog appender instance.
      #
      # Parameters
      #   url: [String]
      #     Default: 'syslog://localhost'
      #     For writing logs to a remote syslog server
      #     URL of server: protocol://host:port
      #     Uses port 514 by default for TCP and UDP.
      #     local syslog example:          'syslog://localhost'
      #     TCP example with default port: 'tcp://logger'
      #     TCP example with custom port:  'tcp://logger:8514'
      #     UDP example with default port: 'udp://logger'
      #     UDP example with custom port:  'udp://logger:8514'
      #     When using the :syslog protocol, logs will always be sent to the localhost syslog
      #
      #   host: [String]
      #     Host name to provide to the remote syslog.
      #     Default: SemanticLogger.host
      #
      #   tcp_client: [Hash]
      #     Default: {}
      #     Only used with the TCP protocol.
      #     The options of the connection: policy:, connect_timeout:, write_timeout:, keepalive:, and ssl:
      #     (see TcpConnection#initialize). The url gives the server, so server: and servers: raise
      #     ArgumentError, as does any other option.
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: none (:trace), so it writes every entry that a logger emits; each logger
      #     filters by its own level.
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      #
      #   application: [String]
      #     Identity of the program.
      #     Default: SemanticLogger.application
      #
      #   max_size: [Integer]
      #     Set your own packet size.
      #     Default: 1024 bytes
      #
      #   options: [Integer]
      #     Default: ::Syslog::LOG_PID | ::Syslog::LOG_CONS (when logging to a local syslog daemon)
      #     Any of the following (options can be logically OR'd together)
      #       ::Syslog::LOG_CONS
      #       ::Syslog::LOG_NDELAY
      #       ::Syslog::LOG_NOWAIT
      #       ::Syslog::LOG_ODELAY
      #       ::Syslog::LOG_PERROR
      #       ::Syslog::LOG_PID
      #    Note:
      #      - Only applicable when logging to a local syslog instance.
      #        I.e. When `url: 'syslog://localhost'`
      #
      #   facility: [Integer]
      #     Default: ::Syslog::LOG_USER (the same value as SemanticLogger::Formatters::Syslog::LOG_USER)
      #     Type of program (can be logically OR'd together)
      #       ::Syslog::LOG_AUTH
      #       ::Syslog::LOG_AUTHPRIV
      #       ::Syslog::LOG_CONSOLE
      #       ::Syslog::LOG_CRON
      #       ::Syslog::LOG_DAEMON
      #       ::Syslog::LOG_FTP
      #       ::Syslog::LOG_KERN
      #       ::Syslog::LOG_LRP
      #       ::Syslog::LOG_MAIL
      #       ::Syslog::LOG_NEWS
      #       ::Syslog::LOG_NTP
      #       ::Syslog::LOG_SECURITY
      #       ::Syslog::LOG_SYSLOG
      #       ::Syslog::LOG_USER
      #       ::Syslog::LOG_UUCP
      #       ::Syslog::LOG_LOCAL0
      #       ::Syslog::LOG_LOCAL1
      #       ::Syslog::LOG_LOCAL2
      #       ::Syslog::LOG_LOCAL3
      #       ::Syslog::LOG_LOCAL4
      #       ::Syslog::LOG_LOCAL5
      #       ::Syslog::LOG_LOCAL6
      #       ::Syslog::LOG_LOCAL7
      #
      #   level_map: [Hash | SemanticLogger::Formatters::Syslog::LevelMap]
      #     Supply a custom map of SemanticLogger levels to syslog levels.
      #
      #   Example:
      #     # Change the warn level to LOG_NOTICE level instead of a the default of LOG_WARNING.
      #     SemanticLogger.add_appender(appender: :syslog, level_map: {warn: ::Syslog::LOG_NOTICE})
      def initialize(url: "syslog://localhost",
                     facility: SemanticLogger::Formatters::Syslog::LOG_USER,
                     max_size: SemanticLogger::Formatters::Syslog::DEFAULT_MAX_SIZE,
                     level_map: SemanticLogger::Formatters::Syslog::LevelMap.new,
                     options: nil,
                     tcp_client: {},
                     **args,
                     &)
        @options            = options
        @facility           = facility
        @max_size           = max_size
        @level_map          = SemanticLogger::Formatters::Syslog::LevelMap.build(level_map)
        @url                = url
        uri                 = Utils.parse_url(@url)
        @server             = uri.host || "localhost"
        @protocol           = (uri.scheme || :syslog).to_sym
        @port               = uri.port || 514
        @server             = "localhost" if @protocol == :syslog

        raise "Unknown protocol #{@protocol}!" unless %i[syslog tcp udp].include?(@protocol)

        # The syslog gem, a bundled gem since Ruby 3.4, is only required when logging to a local syslog daemon.
        if @protocol == :syslog
          begin
            require "syslog"
          rescue LoadError
            raise LoadError,
                  "Missing gem: syslog. This gem is required when logging to a local syslog daemon on Ruby 3.4 " \
                  'and later. Please add the gem "syslog" to your Gemfile.'
          end
          @options ||= ::Syslog::LOG_PID | ::Syslog::LOG_CONS
        end

        @remote_syslog = tcp_connection(tcp_client || {}) if @protocol == :tcp

        # The syslog formatters load the syslog_protocol gem that they use to build remote syslog packets.
        if %i[tcp udp].include?(@protocol)
          # Reject an invalid facility when the appender is created, even with a formatter that ignores it.
          SemanticLogger::Formatters::Syslog.facility_number(@facility)
        end

        super(**args, &)
        reopen
      end

      # Set the formatter from Symbol|Hash|Block, as for any appender.
      #
      # When sending over TCP or UDP, a formatter named as one of the PACKET_FORMATTERS also gets
      # this appender's facility, level map, and maximum packet size, whether it is supplied when
      # the appender is created or set later.
      def formatter=(formatter)
        super(%i[tcp udp].include?(@protocol) ? with_packet_options(formatter) : formatter)
      end

      # After forking an active process call #reopen to re-open
      # open the handles to resources
      #
      # Over TCP, it connects again, and then closes the connection it replaces, such as after a log rotation.
      # When connecting fails, it reports that to the internal logger and keeps the connection it has, if any; with
      # none, as when it is added, or after a fork, the next write connects. After a fork, the connection inherited
      # from the parent is left to it (see TcpConnection). Over UDP, it closes the socket it replaces, which in a
      # forked child is only the child's copy.
      def reopen
        case @protocol
        when :syslog
          method = ::Syslog.opened? ? :reopen : :open
          ::Syslog.send(method, application, options, facility)
        when :tcp
          reopen_tcp
        when :udp
          replaced       = @remote_syslog
          @remote_syslog = UDPSocket.new
          close_remote_syslog(replaced, replaced: true)
        else
          raise "Unsupported protocol: #{@protocol}"
        end
      end

      # Closes the connection to a remote syslog server, such as when the appender is removed, so that the next
      # write connects again over TCP, or opens a new socket over UDP. The local syslog is left open, since
      # ::Syslog is shared by the whole process. An error closing it is reported to the internal logger, rather
      # than raised.
      def close
        case @protocol
        when :tcp
          error = @remote_syslog.close
          logger.warn("Could not close the connection to the syslog server", error) if error
        when :udp
          close_remote_syslog(@remote_syslog)
          @remote_syslog = nil
        end
      ensure
        super
      end

      # Write the log using the specified protocol and server. Connects over TCP, or opens a socket over UDP,
      # first when the appender has none, such as after #close.
      def log(log)
        case @protocol
        when :syslog
          # Since the Ruby Syslog API supports sprintf format strings, double up all existing '%'
          message = format_log(log).gsub "%", "%%"
          ::Syslog.log @level_map[log.level], message
        when :tcp
          @remote_syslog.write("#{format_log(log)}\r\n")
        when :udp
          (@remote_syslog ||= UDPSocket.new).send(format_log(log), 0, @server, @port)
        else
          raise "Unsupported protocol: #{protocol}"
        end
        true
      end

      # Flush is called by the semantic_logger during shutdown.
      def flush
        @remote_syslog.flush if @remote_syslog.respond_to?(:flush)
      end

      # Over UDP, a log message too large for a datagram (Errno::EMSGSIZE) cannot be sent by retrying.
      def message_error?(exception)
        (@protocol == :udp && exception.is_a?(Errno::EMSGSIZE)) || super
      end

      # Over TCP, whether nothing of the entry was written, since it could not connect, or the write failed before
      # any of it was sent, so that it is written again after the back-off. See Subscriber#wrote_nothing?.
      def wrote_nothing?(exception)
        @protocol == :tcp && @remote_syslog.nothing_sent?(exception)
      end

      # Over TCP, whether the entry never reached the server, since it could not connect. See Subscriber#not_sent?.
      def not_sent?(exception)
        @protocol == :tcp && @remote_syslog.not_connected?(exception)
      end

      # Returns [SemanticLogger::Formatters::Base] default formatter for this Appender
      # depending on the protocol selected
      def default_formatter
        if protocol == :syslog
          # Format is text output without the time.
          # Escape control characters so untrusted log data cannot forge syslog entries.
          # Exception details are off, as with the remote syslog formatters, so existing records do not change.
          SemanticLogger::Formatters::Default.new(
            time_format: :notime, escape_control_chars: true, log_exception_details: false
          )
        else
          SemanticLogger::Formatters::Syslog.new(facility: facility, level_map: level_map, max_size: max_size)
        end
      end

      # The formatters that build remote syslog packets, and so need this appender's facility, level map,
      # and maximum packet size.
      PACKET_FORMATTERS = %i[syslog syslog_cee].freeze
      private_constant :PACKET_FORMATTERS

      # The url without any credentials. See Subscriber#inspect.
      def inspect_details
        "url=#{Utils.redacted_url(url).inspect}"
      end

      private

      # Returns [TcpConnection] the connection to the server in the url, with the options given as tcp_client:,
      # which does not connect until the appender is reopened. Raises ArgumentError for server: or servers:
      # in them, since the url gives the server. An option given as nil sets nothing.
      def tcp_connection(options)
        options = options.compact
        if options.key?(:server) || options.key?(:servers)
          raise(ArgumentError,
                "tcp_client: takes no server: or servers:, since the url gives the server: #{Utils.redacted_url(url)}")
        end

        TcpConnection.new(**options, server: "#{@server}:#{@port}")
      end

      # Connects to the syslog server again, and closes the connection that it replaces. Reports, rather than raises,
      # a failure to connect, keeping the connection it has, if any, or else connecting at the next write, behind the
      # back-off while it cannot; and an error closing the connection it replaced.
      def reopen_tcp
        error = @remote_syslog.reopen
        logger.warn("Could not close the connection to the syslog server that a reopen replaced", error) if error
      rescue TcpConnection::ConnectError => e
        logger.warn("Could not connect to the syslog server: the next write connects, if it has no connection", e)
      end

      # Closes the given UDP socket, if any: the one that a reopen replaced, when replaced: is true. Reports an
      # error to the internal logger as a warning, rather than raising it.
      def close_remote_syslog(remote_syslog, replaced: false)
        remote_syslog&.close
      rescue StandardError => e
        logger.warn("Could not close the connection to the syslog server#{' that a reopen replaced' if replaced}", e)
      end

      # Returns the supplied formatter, with this appender's facility, level map, and
      # maximum packet size added when it names one of the PACKET_FORMATTERS, so that they are not
      # silently ignored. Options in a
      # `{syslog: {...}}` Hash take precedence. A formatter instance keeps its own settings.
      def with_packet_options(formatter)
        name, options = formatter.is_a?(Hash) ? formatter.first : [formatter, {}]
        return formatter unless name.respond_to?(:to_sym) && PACKET_FORMATTERS.include?(name.to_sym)

        {name.to_sym => {facility: facility, level_map: level_map, max_size: max_size}.merge(options || {})}
      end
    end
  end
end
