require 'syslog'
require 'uri'
require 'socket'

# Send log messages to local syslog, or remote syslog servers over TCP or UDP.
#
# Example: Log to a local Syslog daemon
#   SemanticLogger.add_appender(SemanticLogger::Appender::Syslog.new)
#
# Example: Log to a remote Syslog server using TCP:
#   appender        = SemanticLogger::Appender::Syslog.new(
#     server: 'tcp://myloghost:514'
#   )
#
#   # Optional: Add filter to exclude health_check, or other log entries
#   appender.filter = Proc.new { |log| log.message !~ /(health_check|Not logged in)/ }
#
#   SemanticLogger.add_appender(appender)
#
# Example: Log to a remote Syslog server using UDP:
#   appender        = SemanticLogger::Appender::Syslog.new(
#     server: 'udp://myloghost:514'
#   )
#
#   # Optional: Add filter to exclude health_check, or other log entries
#   appender.filter = Proc.new { |log| log.message !~ /(health_check|Not logged in)/ }
#
#   SemanticLogger.add_appender(appender)
module SemanticLogger
  module Appender
    class Syslog < SemanticLogger::Appender::Base

      attr_reader :remote_syslog, :server, :host, :port, :protocol, :facility, :local_hostname

      # Default mapping of ruby log levels to syslog log levels
      #
      # ::Syslog::LOG_EMERG   - "System is unusable"
      # ::Syslog::LOG_ALERT   - "Action needs to be taken immediately"
      # ::Syslog::LOG_CRIT    - "A critical condition has occurred"
      # ::Syslog::LOG_ERR     - "An error occurred"
      # ::Syslog::LOG_WARNING - "Warning of a possible problem"
      # ::Syslog::LOG_NOTICE  - "A normal but significant condition occurred"
      # ::Syslog::LOG_INFO    - "Informational message"
      # ::Syslog::LOG_DEBUG   - "Debugging information"
      DEFAULT_LEVEL_MAP = {
        fatal: ::Syslog::LOG_CRIT,
        error: ::Syslog::LOG_ERR,
        warn:  ::Syslog::LOG_WARNING,
        info:  ::Syslog::LOG_NOTICE,
        debug: ::Syslog::LOG_INFO,
        trace: ::Syslog::LOG_DEBUG
      }

      # For more information on the Syslog constants used below see http://ruby-doc.org/stdlib-2.0.0/libdoc/syslog/rdoc/Syslog.html
      # Parameters
      #
      #   :ident [String]
      #     Identity of the program
      #     Default: 'ruby'
      #
      #   :options [Integer]
      #     Default: ::Syslog::LOG_PID | ::Syslog::LOG_CONS
      #     Any of the following (options can be logically OR'd together)
      #       ::Syslog::LOG_CONS
      #       ::Syslog::LOG_NDELAY
      #       ::Syslog::LOG_NOWAIT
      #       ::Syslog::LOG_ODELAY
      #       ::Syslog::LOG_PERROR
      #       ::Syslog::LOG_PID
      #
      #   :facility [Integer]
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
      #   :level [Symbol]
      #     Default: SemanticLogger's log level.
      #     The minimum level at which this appender will write logs. Any log messages below this level will be ignored.
      #
      #   :level_map [Hash]
      #     Supply a custom map of SemanticLogger levels to syslog levels.
      #     For example, passing in { warn: ::Syslog::LOG_NOTICE }
      #       would result in a log mapping that matches the default level map,
      #       except for :warn, which ends up with a LOG_NOTICE level instead of a
      #       LOG_WARNING one.
      #     Without overriding any parameters, the level map will be
      #       LEVEL_MAP = {
      #         fatal:   ::Syslog::LOG_CRIT,
      #         error:   ::Syslog::LOG_ERR,
      #         warn:    ::Syslog::LOG_WARNING,
      #         info:    ::Syslog::LOG_NOTICE,
      #         debug:   ::Syslog::LOG_INFO,
      #         trace:   ::Syslog::LOG_DEBUG
      #       }
      #
      #   :local_hostname [String]
      #     Default: Socket.gethostname || `hostname`.strip
      #     Hostname to provide to the remote syslog.
      #
      #   :server [String]
      #     Default: 'syslog://localhost'
      #     For writing logs to a remote syslog server
      #     URI of server: protocol://host:port
      #     Uses port 514 by default for TCP and UDP.
      #     local syslog example:          'syslog://localhost'
      #     TCP example with default port: 'tcp://logger'
      #     TCP example with custom port:  'tcp://logger:8514'
      #     UDP example with default port: 'udp://logger'
      #     UDP example with custom port:  'udp://logger:8514'
      #     When using the :syslog protocol, logs will always be sent to the localhost syslog
      #
      #   :tcp_client [Hash]
      #     Default: {}
      #     Only used with the TCP protocol.
      #     Specify custom parameters to pass into Net::TCPClient.new
      #     For a list of options see the net_tcp_client documentation:
      #       https://www.omniref.com/ruby/gems/net_tcp_client/1.0.0/symbols/Net::TCPClient/initialize
      def initialize(options = {}, &block)
        options             = options.dup
        @ident              = options.delete(:ident) || 'ruby'
        @options            = options.delete(:options) || (::Syslog::LOG_PID | ::Syslog::LOG_CONS)
        @facility           = options.delete(:facility) || ::Syslog::LOG_USER
        filter              = options.delete(:filter)
        level               = options.delete(:level)
        level_map           = options.delete(:level_map)
        @server             = options.delete(:server) || 'syslog://localhost'
        uri                 = URI(@server)
        @host               = uri.host || 'localhost'
        @protocol           = (uri.scheme || :syslog).to_sym
        @host               = 'localhost' if @protocol == :syslog
        @port               = URI(@server).port || 514
        @local_hostname     = options.delete(:local_hostname) || Socket.gethostname || `hostname`.strip
        @tcp_client_options = options.delete(:tcp_client)

        raise "Unknown protocol #{@protocol}!" unless [:syslog, :tcp, :udp].include?(@protocol)
        raise(ArgumentError, "Unknown options: #{options.inspect}") if options.size > 0

        @level_map = DEFAULT_LEVEL_MAP.dup
        @level_map.update(level_map) if level_map

        # The syslog_protocol gem is required when logging over TCP or UDP.
        if [:tcp, :udp].include?(@protocol)
          begin
            require 'syslog_protocol'
          rescue LoadError
            raise 'Missing gem: syslog_protocol. This gem is required when logging over TCP or UDP. To fix this error: gem install syslog_protocol'
          end

          # The net_tcp_client gem is required when logging over TCP.
          if protocol == :tcp
            @tcp_client_options          ||= {}
            @tcp_client_options[:server] = "#{@host}:#{@port}"
            begin
              require 'net/tcp_client'
            rescue LoadError
              raise 'Missing gem: net_tcp_client. This gem is required when logging over TCP. To fix this error: gem install net_tcp_client'
            end
          end
        end

        reopen

        super(level, filter, &block)
      end

      # After forking an active process call #reopen to re-open
      # open the handles to resources
      def reopen
        case @protocol
        when :syslog
          ::Syslog.open(@ident, @options, @facility)
        when :tcp
          # Use the local logger for @remote_syslog so errors with the remote logger can be recorded locally.
          @tcp_client_options[:logger] = SemanticLogger::Logger.logger
          @remote_syslog               = Net::TCPClient.new(@tcp_client_options)
        when :udp
          @remote_syslog = UDPSocket.new
        else
          raise "Unsupported protocol: #{@protocol}"
        end
      end

      # Write the log using the specified protocol and host.
      def log(log)
        # Ensure minimum log level is met, and check filter
        return false if (level_index > (log.level_index || 0)) || !include_message?(log)

        case @protocol
        when :syslog
          # Since the Ruby Syslog API supports sprintf format strings, double up all existing '%'
          message = formatter.call(log, self).gsub '%', '%%'
          ::Syslog.log @level_map[log.level], message
        when :tcp
          @remote_syslog.retry_on_connection_failure { @remote_syslog.write("#{syslog_packet_formatter(log)}\r\n") }
        when :udp
          @remote_syslog.send syslog_packet_formatter(log), 0, @host, @port
        else
          raise "Unsupported protocol: #{protocol}"
        end
        true
      end

      # Flush is called by the semantic_logger during shutdown.
      def flush
        @remote_syslog.flush if @remote_syslog && @remote_syslog.respond_to?(:flush)
      end

      # Custom log formatter for syslog.
      # Only difference is the removal of the timestamp string since it is in the syslog packet.
      def default_formatter
        Proc.new do |log|
          # Header with date, time, log level and process info
          entry = "#{log.level_to_s} [#{log.process_info}]"

          # Tags
          entry << ' ' << log.tags.collect { |tag| "[#{tag}]" }.join(' ') if log.tags && (log.tags.size > 0)

          # Duration
          entry << " (#{log.duration_human})" if log.duration

          # Class / app name
          entry << " #{log.name}"

          # Log message
          entry << " -- #{log.message}" if log.message

          # Payload
          if payload = log.payload_to_s(false)
            entry << ' -- ' << payload
          end

          # Exceptions
          if log.exception
            entry << " -- Exception: #{log.exception.class}: #{log.exception.message}\n"
            entry << log.backtrace_to_s
          end
          entry
        end
      end

      # Format the syslog packet so it can be sent over TCP or UDP
      def syslog_packet_formatter(log)
        packet          = SyslogProtocol::Packet.new
        packet.hostname = @local_hostname
        packet.facility = @facility
        packet.severity = @level_map[log.level]
        packet.tag      = @ident
        packet.content  = default_formatter.call(log, self)
        packet.time     = log.time
        packet.to_s
      end
    end
  end
end
