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
    # Example, with connection retry options:
    #   SemanticLogger.add_appender(
    #     appender:               :tcp,
    #     server:                 'server:3300',
    #     connect_retry_interval: 0.1,
    #     connect_retry_count:    5
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
      #   The appender passes these to Net::TCPClient.new (net_tcp_client v2.2), which raises
      #   ArgumentError for any other keyword.
      #
      #   :server [String]
      #     The server to connect to, as "host:port", such as 'localhost:2000' or '192.168.1.10:80'.
      #     Net::TCPClient connects over IPv4 only, so the host must be an IPv4 address or a host name
      #     that has one.
      #
      #   :servers [Array of String]
      #     The servers to connect to, each as "host:port", such as ['server1:2000', 'server2:2000'].
      #
      #     Each connection tries the servers in the order of :policy, moving on to the next only
      #     when one cannot be connected to or times out on connect. A host name with several IPv4
      #     addresses is tried at each of them. A failure while writing does not move on to the next
      #     server: the appender reconnects, trying the servers again in the order of :policy.
      #
      #   :connect_timeout [Float]
      #     Seconds to wait for a connection to a server, and for the SSL handshake unless
      #     :ssl gives a :handshake_timeout. A value of -1 waits forever.
      #     Default: 10
      #
      #   :write_timeout [Float]
      #     Seconds to wait while writing a log message. A value of -1 waits forever.
      #     Default: 60
      #
      #   :read_timeout [Float]
      #     Seconds to wait on a read. The appender only writes, so this applies only to the reads
      #     of an :on_connect Proc. A value of -1 waits forever.
      #     Default: 60
      #
      #   :buffered [Boolean]
      #     Whether to use Nagle's algorithm (https://en.wikipedia.org/wiki/Nagle%27s_algorithm),
      #     which holds back small writes to send them together. false sends each log message at once.
      #     Default: true
      #
      #   :keepalive [Boolean]
      #     Whether the operating system checks the connection while it is idle, so that a lost
      #     connection fails on the next write instead of after a long wait.
      #     Default: true
      #
      #   :connect_retry_count [Integer]
      #     Number of times to try connecting again when no server can be connected to.
      #     Default: 10
      #
      #   :connect_retry_interval [Float]
      #     Seconds to wait before each of those retries.
      #     Default: 0.5
      #
      #   :retry_count [Integer]
      #     Number of times to reconnect and write a log message again when the connection fails
      #     while writing it. Each reconnect also retries as set by :connect_retry_count.
      #     Default: 3
      #
      #   :on_connect [Proc]
      #     Called with the Net::TCPClient after each connection is made, including reconnects,
      #     before any log message is written to it.
      #     Typical Use Cases:
      #     - Pass any authentication information to the server
      #     - Perform a handshake with the server
      #
      #   :policy [:ordered | :random | Proc]
      #     The order in which to try the servers when connecting.
      #       :ordered
      #         In the order supplied, so the second server is connected to only when the first
      #         cannot be.
      #       :random
      #         In a random order, chosen again for every connection, including reconnects.
      #       Proc:
      #         Called before each attempt with the Array of Net::TCPClient::Address to try, one for
      #         each IPv4 address of each server, and the number of the attempt, starting at 1.
      #         It returns the address to try, or nil to stop: one that never returns nil tries
      #         forever when no server can be reached.
      #           Example, the servers in reverse order:
      #             policy: ->(addresses, count) { addresses.reverse[count - 1] }
      #     Default: :ordered
      #
      #   :close_on_error [Boolean]
      #     Whether to close the connection when a write fails or times out, so that the next
      #     write reconnects instead of using a connection in an unknown state.
      #     Default: true
      #
      #   :ssl [true | Hash]
      #     true: Connect with SSL (TLS), verifying the server's certificate and host name against
      #       the system's trusted certificates.
      #     Hash: Connect with SSL, using these OpenSSL::SSL::SSLContext parameters, such as
      #       ca_file, cert, key, min_version, or verify_mode, and
      #       handshake_timeout: the seconds to wait for the SSL handshake. Default: :connect_timeout
      #     Default: nil (no SSL)
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
      #
      # Example, with connection retry options:
      #   SemanticLogger.add_appender(
      #     appender:               :tcp,
      #     server:                 'server:3300',
      #     connect_retry_interval: 0.1,
      #     connect_retry_count:    5
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
        reopen
      end

      # After forking an active process call #reopen to re-open the handles to resources.
      def reopen
        close
        @tcp_client = Net::TCPClient.new(**@tcp_client_args)
      end

      # Write the log using the specified protocol and server.
      def log(log)
        message = format_log(log)
        @tcp_client.retry_on_connection_failure do
          @tcp_client.write("#{message}#{separator}")
        end
        true
      end

      # Flush is called by the semantic_logger during shutdown.
      def flush
        @tcp_client&.flush
      end

      # Close is called during shutdown, or with reopen
      def close
        @tcp_client&.close
      end

      # Only the servers: the other options can hold TLS keys and passwords. See Subscriber#inspect.
      def inspect_details
        "server=#{(@tcp_client_args[:server] || @tcp_client_args[:servers]).inspect}"
      end

      private

      # Returns [SemanticLogger::Formatters::Default] formatter default for this Appender
      def default_formatter
        SemanticLogger::Formatters::Json.new
      end
    end
  end
end
