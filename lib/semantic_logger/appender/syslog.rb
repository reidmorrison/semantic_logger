require "syslog"
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
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: SemanticLogger.default_level
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
      #     Default: ::Syslog::LOG_PID | ::Syslog::LOG_CONS
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
      #     Default: ::Syslog::LOG_USER
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
                     facility: ::Syslog::LOG_USER,
                     max_size: 1024,
                     level_map: SemanticLogger::Formatters::Syslog::LevelMap.new,
                     options: ::Syslog::LOG_PID | ::Syslog::LOG_CONS,
                     tcp_client: {},
                     **args,
                     &block)

        @options            = options
        @facility           = facility
        @max_size           = max_size
        @level_map          = level_map
        @url                = url
        uri                 = URI(@url)
        @server             = uri.host || "localhost"
        @protocol           = (uri.scheme || :syslog).to_sym
        @port               = uri.port || 514
        @server             = "localhost" if @protocol == :syslog
        @tcp_client_options = tcp_client

        raise "Unknown protocol #{@protocol}!" unless %i[syslog tcp udp].include?(@protocol)

        # The syslog_protocol gem is required when logging over TCP or UDP.
        if %i[tcp udp].include?(@protocol)
          begin
            require "syslog_protocol"
          rescue LoadError
            raise LoadError,
                  "Missing gem: syslog_protocol. This gem is required when logging over TCP or UDP. To fix this error: gem install syslog_protocol"
          end

          # The net_tcp_client gem is required when logging over TCP.
          if protocol == :tcp
            begin
              require "net/tcp_client"
            rescue LoadError
              raise LoadError,
                    "Missing gem: net_tcp_client. This gem is required when logging over TCP. To fix this error: gem install net_tcp_client"
            end
          end
        end

        super(**args, &block)
        reopen
      end

      # After forking an active process call #reopen to re-open
      # open the handles to resources
      def reopen
        case @protocol
        when :syslog
          method = ::Syslog.opened? ? :reopen : :open
          ::Syslog.send(method, application, options, facility)
        when :tcp
          @tcp_client_options[:server] = "#{@server}:#{@port}"
          @remote_syslog               = Net::TCPClient.new(**@tcp_client_options)
          # Use the local logger for @remote_syslog so errors with the remote logger can be recorded locally.
          @remote_syslog.logger = logger
        when :udp
          @remote_syslog = UDPSocket.new
        else
          raise "Unsupported protocol: #{@protocol}"
        end
      end

      # Write the log using the specified protocol and server.
      def log(log)
        case @protocol
        when :syslog
          # Since the Ruby Syslog API supports sprintf format strings, double up all existing '%'
          message = formatter.call(log, self).gsub "%", "%%"
          ::Syslog.log @level_map[log.level], message
        when :tcp
          @remote_syslog.retry_on_connection_failure { @remote_syslog.write("#{formatter.call(log, self)}\r\n") }
        when :udp
          @remote_syslog.send(formatter.call(log, self), 0, @server, @port)
        else
          raise "Unsupported protocol: #{protocol}"
        end
        true
      end

      # Flush is called by the semantic_logger during shutdown.
      def flush
        @remote_syslog.flush if @remote_syslog.respond_to?(:flush)
      end

      # Returns [SemanticLogger::Formatters::Base] default formatter for this Appender depending on the protocal selected
      def default_formatter
        if protocol == :syslog
          # Format is text output without the time
          SemanticLogger::Formatters::Default.new(time_format: nil)
        else
          SemanticLogger::Formatters::Syslog.new(facility: facility, level_map: level_map, max_size: max_size)
        end
      end
    end
  end
end
