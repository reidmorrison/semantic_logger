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
      #     Specify custom parameters to pass into Net::TCPClient.new
      #     For a list of options see the net_tcp_client documentation:
      #       https://github.com/reidmorrison/net_tcp_client/blob/master/lib/net/tcp_client/tcp_client.rb
      #     v6 takes only policy: (:ordered or :random), connect_timeout:, write_timeout:, keepalive:, and
      #     ssl:, plus connect_retry_count: 0, retry_count: 0, buffered: false, and connect_retry_interval:
      #     with connect_retry_count: 0, so the others report a deprecation warning (see TcpClientOptions).
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
        @tcp_client_options = tcp_client || {}

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

        # The net_tcp_client gem is required when logging over TCP.
        # The syslog formatters load the syslog_protocol gem that they use to build remote syslog packets.
        if @protocol == :tcp
          begin
            require "net/tcp_client"
          rescue LoadError
            raise LoadError,
                  "Missing gem: net_tcp_client. This gem is required when logging over TCP. " \
                  "To fix this error: gem install net_tcp_client"
          end
        end

        if %i[tcp udp].include?(@protocol)
          # Reject an invalid facility when the appender is created, even with a formatter that ignores it.
          SemanticLogger::Formatters::Syslog.facility_number(@facility)
        end

        super(**args, &)
        if @protocol == :tcp
          TcpClientOptions.report_deprecated(
            @tcp_client_options, ":syslog",
            server:  "it is ignored, since the url gives the server",
            servers: "it replaces the server of the url, which v6 always connects to: give that server in the url"
          )
          logger.extend(TcpClientOptions::BenchmarkWithoutWarning) if TcpClientOptions.report_outdated_gem(":syslog")
        end
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
      # When connecting fails, it raises, and keeps the connection it has. Over UDP, it closes the socket it
      # replaces, which in a forked child is only the child's copy.
      #
      # Over TCP, a child process first forgets the client it inherited, without closing its connection, which
      # belongs to the parent. The child closes only its own copy of the socket's file descriptor, which sends
      # the server nothing, so that the server sees the connection end once the parent closes it, rather than
      # once the child exits, or collects the client. When connecting fails in the child, such as while the
      # server cannot be reached, the appender connects again on its next write, rather than writing through
      # the parent's connection. Over TLS, both processes would then carry on the same TLS session, so that the
      # server could not decrypt what the parent writes next.
      def reopen
        case @protocol
        when :syslog
          method = ::Syslog.opened? ? :reopen : :open
          ::Syslog.send(method, application, options, facility)
        when :tcp
          forget_inherited
          replaced = @remote_syslog
          connect_tcp
          close_remote_syslog(replaced, replaced: true)
        when :udp
          replaced       = @remote_syslog
          @remote_syslog = UDPSocket.new
          close_remote_syslog(replaced, replaced: true)
        else
          raise "Unsupported protocol: #{@protocol}"
        end
      end

      # Closes the connection to a remote syslog server, such as when the appender is removed, and forgets it, so
      # that the next write connects again over TCP, or opens a new socket over UDP. The local syslog is left
      # open, since ::Syslog is shared by the whole process. An error closing it is reported to the internal
      # logger, rather than raised.
      #
      # Over TCP, in a forked child that has not reopened, such as one that removes the appender before its
      # reopen has run, it forgets the client it inherited instead, without closing its connection, which
      # belongs to the parent (see #reopen).
      def close
        forget_inherited if @protocol == :tcp
        close_remote_syslog(@remote_syslog)
      ensure
        @remote_syslog = nil
      end

      # Write the log using the specified protocol and server. Connects over TCP, or opens a socket over UDP,
      # first when the appender has none: after #close, or over TCP when connecting failed as it was reopened
      # after a fork.
      def log(log)
        case @protocol
        when :syslog
          # Since the Ruby Syslog API supports sprintf format strings, double up all existing '%'
          message = format_log(log).gsub "%", "%%"
          ::Syslog.log @level_map[log.level], message
        when :tcp
          client = @remote_syslog || connect_tcp
          client.retry_on_connection_failure { client.write("#{format_log(log)}\r\n") }
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

      # Returns [Net::TCPClient] a new client, connected to the server, after making it the appender's. Records
      # the process that built it, which owns its connection (see #reopen).
      def connect_tcp
        @remote_syslog = Net::TCPClient.new(**tcp_client_options)
        # Use the local logger for @remote_syslog so errors with the remote logger can be recorded locally.
        @remote_syslog.logger = logger
        @pid                  = ::Process.pid
        @remote_syslog
      end

      # In a child process, forgets the TCP client built in the parent before a fork, and then closes the child's
      # copy of its socket's file descriptor, without a TLS shutdown: SSLSocket#to_io is the TCPSocket under it.
      # See #reopen.
      def forget_inherited
        return if @pid == ::Process.pid

        inherited      = @remote_syslog
        @remote_syslog = nil
        socket         = inherited&.socket&.to_io
        socket.close unless socket.nil? || socket.closed?
      end

      # Closes the given TCP client or UDP socket, if any: the one that a reopen replaced, when replaced: is true.
      # Reports an error to the internal logger as a warning, rather than raising it.
      def close_remote_syslog(remote_syslog, replaced: false)
        remote_syslog&.close
      rescue StandardError => e
        logger.warn("Could not close the connection to the syslog server#{' that a reopen replaced' if replaced}", e)
      end

      # Returns [Hash] a copy of the options given as tcp_client: (see Subscriber#copy_options), with the server
      # from the url, for a new Net::TCPClient, since it takes handshake_timeout: out of the ssl: Hash it is
      # given: each client gets a copy of its own, which keeps the timeout for the next one, such as after a
      # reopen.
      def tcp_client_options
        copy_options(@tcp_client_options).merge(server: "#{@server}:#{@port}")
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
