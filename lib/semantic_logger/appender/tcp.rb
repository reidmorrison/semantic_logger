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
    # * Fails over to the next server, and reconnects when a connection is lost (see TcpConnection).
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
      # Connection Parameters (see TcpConnection#initialize):
      #   server: [String]
      #     The server to connect to, as "host:port", such as 'localhost:2000', with an IPv6 address in
      #     brackets, such as '[::1]:2000'.
      #
      #   servers: [Array of String]
      #     Instead of server:, several servers, each tried in turn when the one before cannot be connected to.
      #
      #   policy: [:ordered | :random]
      #     The order to try the servers in. Default: :ordered
      #
      #   connect_timeout: [Numeric]
      #     Seconds to wait for a server's host name to be looked up, and then for it to accept the connection; a
      #     negative value waits as long as it takes.
      #     Default: 10
      #
      #   write_timeout: [Numeric]
      #     Seconds to wait for a write to complete; a negative value waits as long as it takes. Default: 60
      #
      #   keepalive: [true | false]
      #     Whether to turn on TCP keepalive. Default: true
      #
      #   ssl: [true | Hash]
      #     Connect over TLS: true, or OpenSSL::SSL::SSLContext parameters, plus handshake_timeout:.
      #
      #   A connection parameter given as nil takes its default.
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
                     host: nil, metrics: false, **connection_options, &)
        @separator  = separator
        @tcp_client = TcpConnection.new(**connection_options)

        super(level: level, formatter: formatter, filter: filter, application: application,
              environment: environment, host: host, metrics: metrics, &)
        reopen
      end

      # Connects to the server again, and then closes the connection it replaces, such as after a log rotation,
      # or a fork, reporting an error closing it rather than raising it. When it cannot connect, such as when the
      # appender is added while the server is down, it reports that too, and keeps the connection it has: the next
      # write connects again, and the back-off writes the entry again while it cannot. After a fork, the connection
      # inherited from the parent is left to it (see TcpConnection).
      def reopen
        error = tcp_client.reopen
        logger.warn("Could not close the connection that a reopen replaced", error) if error
      rescue TcpConnection::ConnectError => e
        logger.warn("Could not connect, so the next write connects again", e)
      end

      # Writes the entry, connecting first when the appender has no connection.
      def log(log)
        tcp_client.write("#{format_log(log)}#{separator}")
        true
      end

      # Closes the connection, reporting an error closing it rather than raising it. The next write connects again.
      def close
        error = tcp_client.close
        logger.warn("Could not close the connection", error) if error
      end

      # Whether nothing of the entry was written, since it could not connect, or the write failed before any of it
      # was sent, so that it is written again after the back-off. See Subscriber#wrote_nothing?.
      def wrote_nothing?(exception)
        tcp_client.nothing_sent?(exception)
      end

      # Whether the entry never reached the server, since it could not connect, so that an outage is not counted
      # as a failure to write it. See Subscriber#not_sent?.
      def not_sent?(exception)
        tcp_client.not_connected?(exception)
      end

      # Only the servers: the other options can hold TLS keys and passwords. See Subscriber#inspect.
      def inspect_details
        "servers=#{tcp_client.servers.inspect}"
      end

      private

      # Returns [SemanticLogger::Formatters::Default] formatter default for this Appender
      def default_formatter
        SemanticLogger::Formatters::Json.new
      end
    end
  end
end
