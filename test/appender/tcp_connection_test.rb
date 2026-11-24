require_relative "../test_helper"
require_relative "../tls_server"

module Appender
  class TcpConnectionTest < Minitest::Test
    Connection = SemanticLogger::Appender::TcpConnection

    describe SemanticLogger::Appender::TcpConnection do
      # Returns [TCPServer] a server on 127.0.0.1 that accepts connections, without reading from them until asked.
      def listener
        @listener ||= TCPServer.new("127.0.0.1", 0)
      end

      def server_name(server = listener) = "127.0.0.1:#{server.addr[1]}"

      # Returns [String] a server that refuses connections: a port that was listened on, and is not any more.
      def refusing_server
        closed = TCPServer.new("127.0.0.1", 0)
        port   = closed.addr[1]
        closed.close
        "127.0.0.1:#{port}"
      end

      # Returns [String] the next line read on the given accepted connection, within 2 seconds.
      def line(socket)
        socket.wait_readable(2) && socket.gets
      end

      after do
        @connection&.close
        @listener&.close
      end

      describe "#initialize" do
        it "raises ArgumentError for an option of Net::TCPClient that it does not take, saying why" do
          error = assert_raises(ArgumentError) do
            Connection.new(server: "localhost:1", connect_retry_count: 3, read_timeout: 1, colour: :red)
          end

          assert_includes error.message, "connect_retry_count:, read_timeout:, colour:"
          assert_includes error.message, "connect_retry_count: it does not retry by itself"
          assert_includes error.message, "read_timeout: the appender never reads"
          assert_includes error.message, "colour: it is not an option"
        end

        it "takes the options of Net::TCPClient that say what it does, and ignores them" do
          connection = Connection.new(server: "localhost:1", connect_retry_count: 0, connect_retry_interval: 0.5,
                                      retry_count: 0, buffered: false, read_timeout: nil)

          assert_equal ["localhost:1"], connection.servers
        end

        it "raises ArgumentError for a retry count other than 0, saying to use 0" do
          error = assert_raises(ArgumentError) { Connection.new(server: "localhost:1", retry_count: 3) }

          assert_includes error.message, "it takes only connect_retry_count: 0 and retry_count: 0"
        end

        it "raises ArgumentError for connect_retry_interval: without connect_retry_count: 0" do
          assert_raises(ArgumentError) { Connection.new(server: "localhost:1", connect_retry_interval: 0.5) }
        end

        it "uses the default of each option given as nil" do
          connection = Connection.new(server: "localhost:1", servers: nil, policy: nil, connect_timeout: nil,
                                      write_timeout: nil, keepalive: nil, ssl: nil)

          assert_in_delta 10.0, connection.instance_variable_get(:@connect_timeout)
          assert_in_delta 60.0, connection.instance_variable_get(:@write_timeout)
          assert connection.instance_variable_get(:@keepalive)
          assert_equal :ordered, connection.instance_variable_get(:@policy)
        end

        it "waits as long as it takes for a negative timeout, as Net::TCPClient took -1" do
          over_tls   = Connection.new(server: server_name, ssl: {handshake_timeout: -1})
          connection = Connection.new(server: server_name, connect_timeout: -1, write_timeout: -1)

          assert_nil over_tls.instance_variable_get(:@handshake_timeout)
          assert_nil connection.instance_variable_get(:@connect_timeout)
          assert_nil connection.instance_variable_get(:@write_timeout)
          connection.write("waited\n")
          accepted = listener.accept

          assert_equal "waited\n", line(accepted)
        ensure
          connection&.close
          accepted&.close
        end

        it "raises ArgumentError without a server" do
          assert_raises(ArgumentError) { Connection.new }
        end

        it "raises ArgumentError for a server that is not host:port" do
          ["localhost", "::1:514", "host:port"].each do |server|
            assert_raises(ArgumentError) { Connection.new(server: server) }
          end
        end

        it "takes an IPv6 address in brackets" do
          assert_equal ["[::1]:514"], Connection.new(server: "[::1]:514").servers
        end

        it "raises ArgumentError for a policy other than :ordered or :random" do
          assert_raises(ArgumentError) { Connection.new(server: "localhost:1", policy: :ping_time) }
          assert_raises(ArgumentError) { Connection.new(server: "localhost:1", policy: ->(servers) { servers }) }
        end

        it "leaves the ssl: Hash given as it is, which can be frozen" do
          ssl = {handshake_timeout: 2, verify_mode: OpenSSL::SSL::VERIFY_NONE}.freeze
          Connection.new(server: "localhost:1", ssl: ssl)

          assert_equal({handshake_timeout: 2, verify_mode: OpenSSL::SSL::VERIFY_NONE}, ssl)
        end

        it "does not connect" do
          refute_predicate Connection.new(server: server_name), :connected?
        end
      end

      describe "#reopen" do
        it "connects to the next server when one refuses" do
          @connection = Connection.new(servers: [refusing_server, server_name])
          @connection.reopen

          assert_predicate @connection, :connected?
        end

        it "raises ConnectError naming the servers when it can connect to none, and keeps the connection it has" do
          @connection = Connection.new(server: server_name)
          @connection.reopen
          error = Socket.stub(:tcp, ->(*, **) { raise Errno::ECONNREFUSED }) do
            assert_raises(Connection::ConnectError) { @connection.reopen }
          end

          assert_includes error.message, "Could not connect to #{server_name}: Errno::ECONNREFUSED"
          assert_predicate @connection, :connected?
          assert @connection.not_connected?(error)
        end

        it "bounds both the look-up of the host name and the connection by connect_timeout:" do
          timeouts    = nil
          @connection = Connection.new(server: "a:1", connect_timeout: 3)

          Socket.stub(:tcp, lambda { |*, **options|
            timeouts = options
            raise Errno::ECONNREFUSED
          }) do
            assert_raises(Connection::ConnectError) { @connection.reopen }
          end

          assert_equal({connect_timeout: 3, resolv_timeout: 3}, timeouts)
        end

        it "tries the servers in a random order with policy: :random" do
          tried       = []
          @connection = Connection.new(servers: %w[a:1 b:1 c:1], policy: :random)
          Socket.stub(:tcp, lambda { |host, *, **|
            tried << host
            raise Errno::ECONNREFUSED
          }) do
            20.times { assert_raises(Connection::ConnectError) { @connection.reopen } }
          end

          assert_equal 60, tried.size
          assert_operator tried.each_slice(3).uniq.size, :>, 1
        end

        it "returns an error closing the connection it replaced, rather than raising it" do
          @connection = Connection.new(server: server_name)
          @connection.reopen
          error = Socket.stub_any_instance(:close, -> { raise Errno::ECONNRESET }) { @connection.reopen }

          assert_instance_of Errno::ECONNRESET, error
        end
      end

      describe "#write" do
        it "connects, and writes the data, without holding it back" do
          @connection = Connection.new(server: server_name)
          @connection.write("hello\n")
          accepted = listener.accept

          assert_equal "hello\n", line(accepted)
          # JRuby sets TCP_NODELAY, but cannot read it back (ENOPROTOOPT).
          unless defined?(JRUBY_VERSION)
            socket = @connection.instance_variable_get(:@socket)

            assert socket.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY).bool
          end
        ensure
          accepted&.close
        end

        it "connects again when the server closed the connection, such as one that was idle" do
          @connection = Connection.new(server: server_name)
          @connection.reopen
          listener.accept.close
          sleep 0.05
          @connection.write("after\n")
          accepted = listener.accept

          assert_equal "after\n", line(accepted)
        ensure
          accepted&.close
        end

        it "writes once more on a new connection when the write fails before any of the data was sent" do
          @connection = Connection.new(server: server_name)
          @connection.reopen
          failing = @connection.instance_variable_get(:@socket)
          failing.define_singleton_method(:write_nonblock) { |*, **| raise Errno::EPIPE }
          @connection.write("again\n")
          listener.accept.close
          accepted = listener.accept

          assert_equal "again\n", line(accepted)
        ensure
          accepted&.close
        end

        it "raises WriteError, without writing again, when the write fails after part of the data was sent" do
          @connection = Connection.new(server: server_name)
          @connection.reopen
          socket = @connection.instance_variable_get(:@socket)
          calls  = 0
          socket.define_singleton_method(:write_nonblock) do |*, **|
            calls += 1
            raise Errno::ECONNRESET if calls > 1

            3
          end
          error = assert_raises(Connection::WriteError) { @connection.write("partial\n") }

          refute_kind_of Connection::NothingWritten, error
          refute @connection.nothing_sent?(error)
          refute @connection.not_connected?(error)
          refute_predicate @connection, :connected?
        end

        it "raises ConnectError when it cannot connect" do
          @connection = Connection.new(server: refusing_server)

          assert_raises(Connection::ConnectError) { @connection.write("lost\n") }
        end

        it "raises WriteError, without writing again, when the write times out before any of the data was sent" do
          @connection = Connection.new(server: server_name, write_timeout: 0.1)
          @connection.reopen
          stalled = @connection.instance_variable_get(:@socket)
          stalled.define_singleton_method(:write_nonblock) { |*, **| :wait_writable }
          stalled.define_singleton_method(:wait_writable) { |*| nil }
          error = assert_raises(Connection::NothingWritten) { @connection.write("slow\n") }

          assert_includes error.message, "timed out"
          assert @connection.nothing_sent?(error), "the appender writes it again after its back-off"
          refute @connection.not_connected?(error)
          refute_predicate @connection, :connected?
        end

        it "raises WriteError when the write times out after part of the data was sent" do
          @connection = Connection.new(server: server_name, write_timeout: 0.1)
          @connection.reopen
          stalled = @connection.instance_variable_get(:@socket)
          calls   = 0
          stalled.define_singleton_method(:write_nonblock) { |*, **| (calls += 1) == 1 ? 3 : :wait_writable }
          stalled.define_singleton_method(:wait_writable) { |*| nil }
          error = assert_raises(Connection::WriteError) { @connection.write("slow\n") }

          assert_includes error.message, "timed out"
        end
      end

      describe "over TLS" do
        let(:server) { TlsServer.new }

        after { server.close }

        it "writes over TLS when the certificate is not verified" do
          @connection = Connection.new(server: "127.0.0.1:#{server.port}", ssl: {verify_mode: OpenSSL::SSL::VERIFY_NONE})
          @connection.write("secret\n")

          assert_equal ["secret"], server.received(1, 1)
        end

        it "raises ConnectError for a certificate that does not verify, so that the entry is written again later" do
          @connection = Connection.new(server: "127.0.0.1:#{server.port}", ssl: true)
          error       = assert_raises(Connection::ConnectError) { @connection.write("refused\n") }

          assert_includes error.message, "OpenSSL::SSL::SSLError"
          assert @connection.not_connected?(error)
        end

        it "does not check the host name with verify_hostname: false, but does by default" do
          store = OpenSSL::X509::Store.new
          store.add_cert(TlsServer.context.cert)
          @connection = Connection.new(server: "localhost:#{server.port}",
                                       ssl:    {cert_store: store, verify_hostname: false})
          @connection.write("trusted\n")

          assert_equal ["trusted"], server.received(1, 1)

          checked = Connection.new(server: "localhost:#{server.port}", ssl: {cert_store: store})
          error   = assert_raises(Connection::ConnectError) { checked.reopen }

          assert_match(/hostname|certificate verify failed/, error.message)
        end

        it "checks an IP address against the certificate" do
          store = OpenSSL::X509::Store.new
          store.add_cert(TlsServer.context.cert)
          @connection = Connection.new(server: "127.0.0.1:#{server.port}", ssl: {cert_store: store})
          @connection.write("by address\n")

          assert_equal ["by address"], server.received(1, 1)
        end

        it "raises ConnectError when the handshake times out" do
          @listener   = TCPServer.new("127.0.0.1", 0)
          @connection = Connection.new(server: server_name, ssl: {handshake_timeout: 0.1})
          error       = assert_raises(Connection::ConnectError) { @connection.reopen }

          assert_includes error.message, "timed out"
        end
      end

      describe "#close" do
        it "closes the connection, and the next write connects again" do
          @connection = Connection.new(server: server_name)
          @connection.reopen
          closed = listener.accept

          assert_nil @connection.close

          assert closed.wait_readable(2) && closed.read_nonblock(1, exception: false).nil?
          refute_predicate @connection, :connected?
        ensure
          closed&.close
        end
      end
    end
  end
end
