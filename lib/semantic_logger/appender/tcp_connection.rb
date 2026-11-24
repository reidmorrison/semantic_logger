require "ipaddr"
require "openssl"
require "socket"

module SemanticLogger
  module Appender
    # A connection to a server over TCP, optionally over TLS, for the appenders that write lines to one: `:tcp`, and
    # `:syslog` over TCP. It owns its connection options, which servers it tries, and when it connects again; an
    # appender only asks it to write.
    #
    # It connects to each server once, in the order of its policy, and raises ConnectError when it cannot connect to
    # any of them. It does not retry by itself: the appender's back-off writes the entry again later (see
    # #not_connected?), except that a write that fails before any of it was sent, such as on a connection that the
    # server closed while it was idle, is written once more at once, on a new connection.
    #
    # A connection opened in another process, before a fork, belongs to that process: it is forgotten, and only the
    # child's copy of its file descriptor is closed, without a TLS shutdown, which would end the connection for the
    # parent too. The next write connects again.
    class TcpConnection
      # Raised when a connection cannot be made, or a write fails, so that the appender can tell them apart.
      class Error < SocketError; end

      # Raised when it cannot connect to any of its servers, such as while they cannot be reached, or when the TLS
      # handshake fails. Nothing of the entry was sent.
      class ConnectError < Error; end

      # Raised when a write fails, after it may have sent part of the entry.
      class WriteError < Error; end

      # The options of Net::TCPClient, which Semantic Logger used before v6, that it does not take, with why.
      RETRIES = "it does not retry by itself, so it takes only connect_retry_count: 0 and retry_count: 0: the " \
                "appender writes the entry again after its back-off instead, see async_max_retries:".freeze
      REFUSED = {
        connect_retry_count:    RETRIES,
        connect_retry_interval: "#{RETRIES}, and takes connect_retry_interval: only with connect_retry_count: 0".freeze,
        retry_count:            RETRIES,
        read_timeout:           "the appender never reads",
        buffered:               "each entry is written at once, so it takes only buffered: false",
        close_on_error:         "the connection is closed after any error",
        on_connect:             "it is not called",
        proxy_server:           "it does not connect through a proxy"
      }.freeze
      # The values of those options that it takes, and ignores, since they are what it does.
      ACCEPTED = {connect_retry_count: 0, retry_count: 0, buffered: false}.freeze
      private_constant :RETRIES, :REFUSED, :ACCEPTED

      POLICIES = %i[ordered random].freeze
      private_constant :POLICIES

      # A server as "host:port", with an IPv6 address in brackets.
      SERVER = /\A(?:\[(?<ipv6>[^\[\]]+)\]|(?<host>[^:\[\]]+)):(?<port>\d+)\z/
      private_constant :SERVER

      # The errors of connecting, or of a TLS handshake.
      CONNECT_ERRORS = [SystemCallError, SocketError, IOError, ::IO::TimeoutError, OpenSSL::SSL::SSLError].freeze
      private_constant :CONNECT_ERRORS

      # The errors of writing to a connection.
      WRITE_ERRORS = [SystemCallError, IOError, ::IO::TimeoutError, OpenSSL::SSL::SSLError].freeze
      private_constant :WRITE_ERRORS

      # [Array<String>] the servers, as "host:port", in the order given.
      attr_reader :servers

      # Parameters
      #   server: [String]
      #     The server to connect to, as "host:port", such as "logs.example.com:3300", with an IPv6 address in
      #     brackets, such as "[::1]:3300". A host name is connected to at any of its addresses, IPv4 or IPv6.
      #
      #   servers: [Array<String>]
      #     Instead of server:, several servers, each tried in turn when the one before cannot be connected to.
      #
      #   policy: [:ordered | :random]
      #     The order to try the servers in: as given, or shuffled for each connection.
      #     Default: :ordered
      #
      #   connect_timeout: [Numeric]
      #     Seconds to wait for each server to accept the connection.
      #     Default: 10
      #
      #   write_timeout: [Numeric]
      #     Seconds to wait for a write to complete.
      #     Default: 60
      #
      #   keepalive: [true | false]
      #     Whether to turn on TCP keepalive.
      #     Default: true
      #
      #   ssl: [true | Hash]
      #     Connect over TLS: true, or the parameters of an OpenSSL::SSL::SSLContext, such as
      #     `{ca_file: "/path/to/ca.pem"}`, given to SSLContext#set_params, which verifies the server's certificate
      #     and host name unless they say otherwise, plus `handshake_timeout:`, the seconds to wait for the TLS
      #     handshake, by default connect_timeout:.
      #     Default: nil, plain TCP
      #
      #   connect_retry_count: 0, retry_count: 0, buffered: false
      #     Taken, and ignored, since they are what it does, so that the options of Net::TCPClient that said so
      #     still work. connect_retry_interval: is also ignored alongside connect_retry_count: 0. An option given as
      #     nil sets nothing.
      #
      # Raises ArgumentError for any other option, such as an option of Net::TCPClient that it does not take.
      def initialize(server: nil, servers: nil, policy: :ordered, connect_timeout: 10, write_timeout: 60,
                     keepalive: true, ssl: nil, **refused)
        refuse(refused)
        @servers = Array(servers || server).map(&:to_s).freeze
        raise(ArgumentError, "Missing :server, or :servers") if @servers.empty?

        @endpoints         = @servers.map { |name| endpoint(name) }.freeze
        @policy            = policy_option(policy)
        @connect_timeout   = Float(connect_timeout)
        @write_timeout     = Float(write_timeout)
        @keepalive         = keepalive
        @ssl_params        = ssl_params(ssl)
        @handshake_timeout = Float((ssl.is_a?(Hash) && ssl[:handshake_timeout]) || connect_timeout)
        @socket            = nil
      end

      # Connects to a server, and then closes the connection that it replaces, if any. Returns [StandardError | nil]
      # the error closing that connection, for the caller to report, rather than raising it. Raises ConnectError,
      # and keeps the connection it has, when it cannot connect.
      def reopen
        forget_inherited
        replaced = @socket
        @socket  = open_socket
        @pid     = ::Process.pid
        close_socket(replaced)
      end

      # Writes the data, connecting first when it has no connection, or the server closed the one it has. When the
      # write fails before any of the data was sent, it connects again and writes it once more. Raises ConnectError
      # when it cannot connect, and WriteError when the write fails, after closing the connection, so that the
      # next write connects again.
      def write(data)
        forget_inherited
        drop_socket if @socket && closed_by_peer?
        retried = false
        begin
          reopen unless @socket
          sent     = 0
          deadline = monotonic + @write_timeout
          sent += write_some(data.byteslice(sent..), deadline) while sent < data.bytesize
          sent
        rescue *WRITE_ERRORS => e
          drop_socket
          if sent.to_i.positive? || retried
            raise(WriteError, "Could not write to #{@servers.join(', ')}: #{e.class}: #{e.message}")
          end

          retried = true
          retry
        end
      end

      # Closes the connection, if any. The next write connects again. Returns [StandardError | nil] the error closing
      # it, for the caller to report, rather than raising it. In a process other than the one that connected, it
      # forgets the connection instead (see the class).
      def close
        forget_inherited
        closing = @socket
        @socket = nil
        close_socket(closing)
      end

      # Whether it has a connection, opened by this process.
      def connected?
        !@socket.nil? && @pid == ::Process.pid
      end

      # Whether the exception, raised by #write, says that nothing of the data was sent, since it could not
      # connect: the appender can write it again later.
      def not_connected?(exception)
        exception.is_a?(ConnectError)
      end

      private

      def refuse(options)
        refused = options.reject { |name, value| value.nil? || accepted?(name, value, options) }
        return if refused.empty?

        reasons = refused.keys.map { |name| "#{name}: #{REFUSED.fetch(name, 'it is not an option')}" }
        raise(ArgumentError,
              "The TCP connection does not take #{refused.keys.map { |name| "#{name}:" }.join(', ')}, since " \
              "v6 no longer connects with net_tcp_client: #{reasons.join('; ')}.")
      end

      def accepted?(name, value, options)
        return ACCEPTED[:connect_retry_count] == options[:connect_retry_count] if name == :connect_retry_interval

        ACCEPTED.key?(name) && ACCEPTED[name] == value
      end

      # Returns [Array(String, Integer)] the host and port of the server named.
      def endpoint(name)
        match = SERVER.match(name.strip)
        unless match
          raise(ArgumentError,
                "Invalid server #{name.inspect}, it must be \"host:port\", such as \"localhost:3300\", " \
                "with an IPv6 address in brackets, such as \"[::1]:3300\".")
        end

        [match[:ipv6] || match[:host], match[:port].to_i]
      end

      def policy_option(policy)
        return policy if POLICIES.include?(policy)

        raise(ArgumentError, "Invalid policy: #{policy.inspect}, it must be :ordered or :random.")
      end

      # Returns [Hash | nil] its own copy of the SSLContext parameters, without handshake_timeout:, which is its
      # own, so that the Hash given is never changed.
      def ssl_params(ssl)
        return unless ssl
        return {} if ssl == true
        raise(ArgumentError, "Invalid ssl: #{ssl.inspect}, it must be true or a Hash.") unless ssl.is_a?(Hash)

        ssl.except(:handshake_timeout)
      end

      # Returns [Socket | OpenSSL::SSL::SSLSocket] a new connection to the first server, in the order of the policy,
      # that it can connect to. Raises ConnectError naming the last failure when it can connect to none.
      def open_socket
        endpoints = @policy == :random ? @endpoints.shuffle : @endpoints
        failure   = nil
        endpoints.each do |host, port|
          return connect_to(host, port)
        rescue *CONNECT_ERRORS => e
          failure = e
        end
        raise(ConnectError, "Could not connect to #{@servers.join(', ')}: #{failure.class}: #{failure.message}")
      end

      def connect_to(host, port)
        socket = Socket.tcp(host, port, connect_timeout: @connect_timeout)
        socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true) if @keepalive
        @ssl_params ? handshake(socket, host) : socket
      rescue Exception
        socket&.close
        raise
      end

      # Returns [OpenSSL::SSL::SSLSocket] the socket, over TLS, once the handshake has completed within the
      # handshake timeout, and the server's certificate matches the host, unless it is not verified.
      def handshake(socket, host)
        context = OpenSSL::SSL::SSLContext.new
        context.set_params(@ssl_params)
        ssl            = OpenSSL::SSL::SSLSocket.new(socket, context)
        ssl.sync_close = true
        ssl.hostname   = host unless ip_address?(host)
        deadline       = monotonic + @handshake_timeout
        loop do
          result = ssl.connect_nonblock(exception: false)
          break unless %i[wait_readable wait_writable].include?(result)

          wait(socket, result, deadline, "TLS handshake")
        end
        ssl.post_connection_check(host) if context.verify_mode == OpenSSL::SSL::VERIFY_PEER
        ssl
      end

      # Returns [Integer] the bytes of the data written, waiting for the socket to take some until the deadline.
      def write_some(data, deadline)
        loop do
          result = @socket.write_nonblock(data, exception: false)
          return result if result.is_a?(Integer)

          wait(@socket.to_io, result, deadline, "write")
        end
      end

      def wait(io, ready, deadline, action)
        remaining = deadline - monotonic
        ready_in  = remaining.positive? && io.public_send(ready, remaining)
        raise(::IO::TimeoutError, "The #{action} timed out") unless ready_in
      end

      # Whether the server closed the connection, such as one that was idle, which the next write would only find
      # out after the data was accepted, so that it would be lost.
      def closed_by_peer?
        return false unless @socket.to_io.wait_readable(0)

        @socket.read_nonblock(1, exception: false).nil?
      rescue *WRITE_ERRORS
        true
      end

      # Closes the connection, ignoring any error, after a failure.
      def drop_socket
        socket  = @socket
        @socket = nil
        socket&.close
      rescue StandardError
        nil
      end

      # In a process other than the one that connected, forgets the connection, and closes only this process's copy
      # of its file descriptor, without a TLS shutdown: SSLSocket#to_io is the socket under it.
      def forget_inherited
        return if @socket.nil? || @pid == ::Process.pid

        io      = @socket.to_io
        @socket = nil
        io.close unless io.closed?
      end

      # Returns [StandardError | nil] the error closing the socket, if any.
      def close_socket(socket)
        socket&.close
        nil
      rescue StandardError => e
        e
      end

      def ip_address?(host)
        IPAddr.new(host)
        true
      rescue IPAddr::InvalidAddressError
        false
      end

      def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
