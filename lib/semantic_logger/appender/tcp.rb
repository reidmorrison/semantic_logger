begin
  require "net/tcp_client"
rescue LoadError
  raise LoadError,
        'Gem net_tcp_client is required for logging over TCP. Please add the gem "net_tcp_client" to your Gemfile.'
end

raise "Net::TCPClient v2.0 or greater is required to log over TCP" unless Net::TCPClient::VERSION.to_f >= 2.0

module SemanticLogger
  module Appender
    # TCP log appender.
    #
    # Log to a server over a TCP Socket.
    # By default messages are in JSON format.
    #
    # Features:
    # * JSON Formatted messages.
    # * SSL encryption.
    # * Transparently reconnect when a connection is lost.
    #
    # Example:
    #   SemanticLogger.add_appender(
    #     appender: :tcp,
    #     server:   'server:3300',
    #   )
    #
    # Example, with SSL enabled:
    #   SemanticLogger.add_appender(
    #     appender: :tcp,
    #     server:   'server:3300',
    #     ssl:      true
    #   )
    #
    class Tcp < SemanticLogger::Subscriber
      attr_accessor :separator
      attr_reader :tcp_client

      # Create TCP log appender.
      #
      # Net::TCPClient Parameters:
      #   Every keyword argument other than the appender parameters below goes to Net::TCPClient.new,
      #   which raises ArgumentError for a keyword it does not take. See Net::TCPClient#initialize for
      #   them and their defaults, such as connect_timeout:, write_timeout:, policy:, and ssl:
      #     https://github.com/reidmorrison/net_tcp_client/blob/master/lib/net/tcp_client/tcp_client.rb
      #   v6 takes only server:, servers:, policy: (:ordered or :random), connect_timeout:, write_timeout:,
      #   keepalive:, and ssl:, plus connect_retry_count: 0, retry_count: 0, buffered: false, and
      #   connect_retry_interval: with connect_retry_count: 0, so the others report a deprecation warning (see
      #   TcpClientOptions).
      #
      #   :server [String]
      #     The server to connect to, as "host:port", such as 'localhost:2000' or '192.168.1.10:80'.
      #     Net::TCPClient connects over IPv4 only, so the host must be an IPv4 address or a host name
      #     that has one.
      #
      #   :servers [Array of String]
      #     Instead of :server, several servers, each as "host:port".
      #
      # Appender Parameters:
      #   separator: [String]
      #     Separator between every message
      #     Default: "\n"
      #     Note: The separator should not be something that could be output in the formatted log message.
      #
      # Common Appender Parameters:
      #   application: [String]
      #     Name of this application to appear in log messages.
      #     Default: SemanticLogger.application
      #
      #   host: [String]
      #     Name of this host to appear in log messages.
      #     Default: SemanticLogger.host
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: none (:trace), so it writes every entry that a logger emits; each logger
      #     filters by its own level.
      #
      #   formatter: [Object|Proc|Symbol|Hash]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: :json
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      #
      #   metrics: [Boolean]
      #     Also send metric-only entries: a metric without a message or an exception.
      #     Default: false
      #
      # Example:
      #   SemanticLogger.add_appender(
      #     appender: :tcp,
      #     server:   'server:3300'
      #   )
      def initialize(separator: "\n",
                     level: nil, formatter: nil, filter: nil, application: nil, environment: nil,
                     host: nil, metrics: false, **tcp_client_args, &)
        @separator       = separator
        @tcp_client_args = tcp_client_args

        # Use the internal logger so that errors with remote logging are only written locally.
        Net::TCPClient.logger      = logger
        Net::TCPClient.logger.name = "Net::TCPClient"

        super(level: level, formatter: formatter, filter: filter, application: application,
              environment: environment, host: host, metrics: metrics, &)
        TcpClientOptions.report_deprecated(tcp_client_args, ":tcp")
        logger.extend(TcpClientOptions::BenchmarkWithoutWarning) if TcpClientOptions.report_outdated_gem(":tcp")
        reopen
      end

      # Closes the connection, and connects to the server again, such as after a log rotation, or a fork.
      #
      # After a fork, the child first forgets the client it inherited, without closing its connection, which
      # belongs to the parent: closing a TLS connection sends the server a close_notify, which ends it for the
      # parent too. The child closes only its own copy of the socket's file descriptor, which sends the server
      # nothing, so that the server sees the connection end once the parent closes it, rather than once the
      # child exits, or collects the client. When connecting fails in the child, the appender has no client
      # until the next write connects again (see #log), rather than writing through the parent's connection.
      def reopen
        forget_inherited
        close
        connect
      end

      # Write the log using the specified protocol and server. Connects first when the appender has no
      # client, since connecting failed when it was reopened after a fork, or it was closed in a forked
      # child.
      def log(log)
        message    = format_log(log)
        tcp_client = @tcp_client || connect
        tcp_client.retry_on_connection_failure do
          tcp_client.write("#{message}#{separator}")
        end
        true
      end

      # Flush is called by the semantic_logger during shutdown.
      def flush
        @tcp_client&.flush
      end

      # Close is called during shutdown, or with reopen
      #
      # In a forked child that has not reopened, such as one that removes the appender before its reopen has
      # run, it forgets the client it inherited instead, without closing its connection, which belongs to the
      # parent, and the next write connects again (see #reopen).
      def close
        forget_inherited
        @tcp_client&.close
      end

      # Only the servers: the other options can hold TLS keys and passwords. See Subscriber#inspect.
      def inspect_details
        "server=#{(@tcp_client_args[:server] || @tcp_client_args[:servers]).inspect}"
      end

      private

      # Returns [Net::TCPClient] a new client, connected to the server, after making it the appender's.
      # Records the process that built it, which owns its connection (see #reopen).
      def connect
        @tcp_client = Net::TCPClient.new(**tcp_client_options)
        @pid        = ::Process.pid
        @tcp_client
      end

      # In a child process, forgets the client built in the parent before a fork, and then closes the child's
      # copy of its socket's file descriptor, without a TLS shutdown: SSLSocket#to_io is the TCPSocket under
      # it. See #reopen.
      def forget_inherited
        return if @pid == ::Process.pid

        inherited   = @tcp_client
        @tcp_client = nil
        socket      = inherited&.socket&.to_io
        socket.close unless socket.nil? || socket.closed?
      end

      # Returns [Hash] a copy of the options for a new Net::TCPClient (see Subscriber#copy_options), since it
      # takes handshake_timeout: out of the ssl: Hash it is given: each client gets a copy of its own, which
      # keeps the timeout for the next one, such as after a reopen.
      def tcp_client_options
        copy_options(@tcp_client_args)
      end

      # Returns [SemanticLogger::Formatters::Default] formatter default for this Appender
      def default_formatter
        SemanticLogger::Formatters::Json.new
      end
    end
  end
end
