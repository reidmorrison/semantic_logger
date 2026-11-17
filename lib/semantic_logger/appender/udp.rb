require "socket"
module SemanticLogger
  module Appender
    # UDP log appender.
    #
    # Write log messages to UDP.
    # By default messages are in JSON format.
    #
    # Example:
    #   SemanticLogger.add_appender(
    #     appender: :udp,
    #     server:   'server:3300',
    #     metrics:  false
    #   )
    class Udp < SemanticLogger::Subscriber
      # The host and port of a server, with an IPv6 address in brackets, as a URL writes it.
      SERVER = /\A(?:\[(?<ipv6>[^\[\]]+)\]|(?<host>[^:\[\]]+)):(?<port>\d+)\z/
      private_constant :SERVER

      attr_accessor :server, :udp_flags
      attr_reader :socket

      # Create UDP log appender.
      #
      #   server: [String]
      #     The server to write UDP messages to, as "host:port", such as "localhost:8088", with an IPv6
      #     address in brackets, as a URL writes it, such as "[::1]:8088". A host name is sent to over
      #     IPv4 when it has an IPv4 address, and otherwise, or when it cannot connect over IPv4, over IPv6.
      #
      #   udp_flags: [Integer]
      #     Should be a bitwise OR of Socket::MSG_* constants.
      #     Default: 0
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
      #     Default: SemanticLogger.default_level
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
      #     Send metrics only events over udp.
      #     Default: true, with a deprecation warning when it is not supplied, since v6 changes it to false.
      #
      # Limitations:
      # * UDP packet size is limited by the connected network and any routers etc
      #   that the message has to traverse. See https://en.wikipedia.org/wiki/Maximum_transmission_unit
      #
      # Example:
      #   SemanticLogger.add_appender(
      #     appender: :udp,
      #     server:   'server:3300',
      #     metrics:  false
      #   )
      def initialize(server:, udp_flags: 0, metrics: METRICS_NOT_SUPPLIED, **args, &)
        @server    = server
        @udp_flags = udp_flags

        super(metrics: deprecated_metrics_default(metrics, :udp), **args, &)
        reopen
      end

      # After forking an active process call #reopen to re-open
      # open the handles to resources
      #
      # Connects a new socket to the server before closing the one it replaces. When it cannot, it
      # raises, keeping the socket it has: ArgumentError for a server that is not "host:port", or
      # the error from resolving or connecting, such as SocketError for a host name that does not resolve.
      def reopen
        socket     = connected_socket
        old_socket = @socket
        @socket    = socket
        old_socket&.close
      end

      # Write the log using the specified protocol and server.
      def log(log)
        @socket.send(format_log(log), udp_flags)
        true
      end

      # Flush is called by the semantic_logger during shutdown.
      def flush
        @socket&.flush
      end

      # Close is called during shutdown.
      def close
        @socket&.close
      end

      # A log message too large for a datagram (Errno::EMSGSIZE) cannot be sent by retrying.
      def message_error?(exception)
        exception.is_a?(Errno::EMSGSIZE) || super
      end

      # See Subscriber#inspect.
      def inspect_details
        "server=#{server.inspect}"
      end

      private

      # Returns [UDPSocket] a new socket, connected to the first of the server's addresses that it can connect to, as
      # Ruby's own UDPSocket#connect tries the addresses of its socket's family in turn. When it cannot connect to any,
      # raises the error from the last one.
      def connected_socket
        *earlier, last = server_addresses
        earlier.each do |address|
          return connect_to(address)
        rescue SystemCallError
          # Try the next address.
        end
        connect_to(last)
      end

      # Returns [UDPSocket] a new socket of the address's family, connected to it. Closes the socket when it does not
      # return it, such as when connecting raises, or the thread is interrupted.
      def connect_to(address)
        socket = UDPSocket.new(address.afamily)
        socket.connect(address.ip_address, address.ip_port)
        connected = true
        socket
      ensure
        socket&.close unless connected
      end

      # Returns [Array<Addrinfo>] the addresses of the server, in the order to try them. A host in brackets is an IPv6
      # address. Any other host is an IPv4 address, or a name, whose IPv4 addresses come first, so that a name with both
      # is still sent to over IPv4, as when the socket was IPv4 only, followed by its IPv6 addresses, so that a name
      # with only IPv6 addresses can be used. Each family keeps the resolver's order. A name that does not resolve
      # raises the resolver's SocketError, as connecting to it did. Whitespace around the server, such as the newline
      # at the end of an environment variable, is ignored.
      def server_addresses
        match = SERVER.match(server.to_s.strip)
        unless match
          raise(ArgumentError,
                "Invalid :server #{server.inspect}, it must be \"host:port\", such as \"localhost:8088\", " \
                "with an IPv6 address in brackets, such as \"[::1]:8088\".")
        end

        port = match[:port].to_i
        return Addrinfo.getaddrinfo(match[:ipv6], port, :INET6, :DGRAM) if match[:ipv6]

        Addrinfo.getaddrinfo(match[:host], port, nil, :DGRAM).partition(&:ipv4?).flatten
      end

      # Returns [SemanticLogger::Formatters::Json] formatter default for this Appender
      def default_formatter
        SemanticLogger::Formatters::Json.new
      end
    end
  end
end
