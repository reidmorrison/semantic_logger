require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Tcp
module Appender
  class UdpTest < Minitest::Test
    describe SemanticLogger::Appender::Udp do
      let(:appender) { SemanticLogger::Appender::Udp.new(server: "localhost:8088", metrics: true) }
      let(:amessage) { "AppenderUdpTest log message" }

      # Runs the block while Addrinfo.getaddrinfo resolves the name to the addresses, in that order, rather than
      # asking a resolver. Other names resolve as before.
      def resolving(name, *addresses, &)
        getaddrinfo = Addrinfo.method(:getaddrinfo)
        resolve     = lambda do |host, port, *args|
          next getaddrinfo.call(host, port, *args) unless host == name

          addresses.map { |address| Addrinfo.udp(address, port) }
        end
        Addrinfo.stub(:getaddrinfo, resolve, &)
      end

      # Runs the block while Addrinfo.getaddrinfo raises the SocketError of a name that does not resolve, rather than
      # asking a resolver.
      def not_resolving(&)
        error = ->(*) { raise(SocketError, "getaddrinfo: nodename nor servname provided, or not known") }
        Addrinfo.stub(:getaddrinfo, error, &)
      end

      # Runs the block while each new UDP socket of one of the families cannot connect, raising Errno::ENETUNREACH as
      # a socket does on a host with no route for its family. Yields the sockets created.
      def unreachable(*families)
        new_socket = UDPSocket.method(:new)
        created    = []
        build      = lambda do |family|
          socket = new_socket.call(family)
          created << socket
          if families.include?(family)
            socket.define_singleton_method(:connect) { |*| raise(Errno::ENETUNREACH, "family #{family}") }
          end
          socket
        end
        UDPSocket.stub(:new, build) { yield(created) }
      end

      describe "metrics:" do
        let(:metric_only) do
          log        = SemanticLogger::Log.new("Test", :info)
          log.metric = "users/signup"
          log
        end

        it "warns that the default changes in v6, and sends metric-only entries, when it is not supplied" do
          line = __LINE__ + 2
          udp  = assert_deprecated(/udp_test\.rb:#{line}: warning: SemanticLogger: The :udp appender sends/) do
            SemanticLogger::Appender::Udp.new(server: "localhost:8088")
          end

          assert udp.should_log?(metric_only)
        ensure
          udp&.close
        end

        it "leaves metric-only entries out with metrics: false, without a warning" do
          udp = refute_deprecated { SemanticLogger::Appender::Udp.new(server: "localhost:8088", metrics: false) }

          refute udp.should_log?(metric_only)
        ensure
          udp&.close
        end

        it "leaves metric-only entries out with metrics: nil, without a warning, as before" do
          udp = refute_deprecated { SemanticLogger::Appender::Udp.new(server: "localhost:8088", metrics: nil) }

          refute udp.should_log?(metric_only)
        ensure
          udp&.close
        end
      end

      describe "server:" do
        # Returns [Hash] the entry that an appender sends to a server listening on the address, given the server's port
        # to return the appender's server: option.
        def received(family, address)
          receiver = UDPSocket.new(family)
          receiver.bind(address, 0)
          udp = SemanticLogger::Appender::Udp.new(server: yield(receiver.local_address.ip_port), metrics: false)
          udp.info(amessage)

          assert receiver.wait_readable(5), "The server received nothing"
          JSON.parse(receiver.recv(65_535))
        ensure
          udp&.close
          receiver&.close
        end

        it "sends to an IPv6 address in brackets, as a URL writes it" do
          skip("IPv6 is not available") unless Socket.ip_address_list.any?(&:ipv6_loopback?)

          entry = received(Socket::AF_INET6, "::1") { |port| "[::1]:#{port}" }

          assert_equal amessage, entry["message"]
        end

        it "sends to a host name over IPv4, as before" do
          entry = received(Socket::AF_INET, "127.0.0.1") { |port| "localhost:#{port}" }

          assert_equal amessage, entry["message"]
        end

        it "sends to a host name over IPv4 when the name resolves to an IPv6 address first" do
          unless Addrinfo.getaddrinfo("localhost", nil, nil, :DGRAM).first.ipv6?
            skip("localhost does not resolve to an IPv6 address first")
          end

          entry = received(Socket::AF_INET, "127.0.0.1") { |port| "localhost:#{port}" }

          assert_equal amessage, entry["message"]
        end

        it "sends over IPv6 to a host name that has only IPv6 addresses" do
          skip("IPv6 is not available") unless Socket.ip_address_list.any?(&:ipv6_loopback?)

          entry = resolving("logs.example", "::1") do
            received(Socket::AF_INET6, "::1") { |port| "logs.example:#{port}" }
          end

          assert_equal amessage, entry["message"]
        end

        it "sends over IPv4 to a host name that has both, whichever the resolver returns first, as before" do
          entry = resolving("logs.example", "::1", "127.0.0.1") do
            received(Socket::AF_INET, "127.0.0.1") { |port| "logs.example:#{port}" }
          end

          assert_equal amessage, entry["message"]
        end

        it "sends over IPv6 to a host name that has both when it cannot connect over IPv4" do
          skip("IPv6 is not available") unless Socket.ip_address_list.any?(&:ipv6_loopback?)

          entry = resolving("logs.example", "127.0.0.1", "::1") do
            unreachable(Socket::AF_INET) do
              received(Socket::AF_INET6, "::1") { |port| "logs.example:#{port}" }
            end
          end

          assert_equal amessage, entry["message"]
        end

        it "raises the error from the last address when it cannot connect to any, closing each socket" do
          resolving("logs.example", "127.0.0.1", "::1") do
            unreachable(Socket::AF_INET, Socket::AF_INET6) do |sockets|
              error = assert_raises(Errno::ENETUNREACH) do
                SemanticLogger::Appender::Udp.new(server: "logs.example:8088", metrics: false)
              end

              assert_includes error.message, "family #{Socket::AF_INET6}"
              assert_equal(2, sockets.count(&:closed?))
            end
          end
        end

        it "raises SocketError, as before, for a host name that does not resolve" do
          not_resolving do
            assert_raises(SocketError) { SemanticLogger::Appender::Udp.new(server: "logs.example:8088", metrics: false) }
          end
        end

        it "ignores whitespace after the server, such as an environment variable's newline, as before" do
          entry = received(Socket::AF_INET, "127.0.0.1") { |port| "localhost:#{port} \n" }

          assert_equal amessage, entry["message"]
        end

        it "raises ArgumentError for a server without a port" do
          error = assert_raises(ArgumentError) do
            SemanticLogger::Appender::Udp.new(server: "localhost", metrics: false)
          end

          assert_includes error.message, '"localhost"'
          assert_includes error.message, '"host:port"'
        end

        it "raises ArgumentError for an IPv6 address without brackets, whose port cannot be told apart" do
          error = assert_raises(ArgumentError) do
            SemanticLogger::Appender::Udp.new(server: "::1:8088", metrics: false)
          end

          assert_includes error.message, '"[::1]:8088"'
        end

        it "keeps its socket when reopened with a server that is not valid" do
          appender.server = "localhost"

          assert_raises(ArgumentError) { appender.reopen }
          refute_predicate appender.socket, :closed?
        ensure
          appender.close
        end
      end

      describe "#reopen" do
        it "connects a new socket, then closes the one it replaces" do
          socket          = appender.socket
          new_socket      = UDPSocket.new
          connect         = new_socket.method(:connect)
          open_at_connect = nil
          new_socket.define_singleton_method(:connect) do |*args|
            open_at_connect = !socket.closed?
            connect.call(*args)
          end

          UDPSocket.stub(:new, new_socket) { appender.reopen }

          assert open_at_connect, "the socket it replaces should still be open while the new one connects"
          assert_same new_socket, appender.socket
          assert_equal 8088, appender.socket.remote_address.ip_port
          assert_predicate socket, :closed?
        ensure
          appender.close
        end

        it "closes the new socket when connecting is interrupted by an exception that is not a StandardError" do
          socket      = appender.socket
          interrupted = UDPSocket.new
          interrupted.define_singleton_method(:connect) { |*| raise(Interrupt) }

          UDPSocket.stub(:new, interrupted) do
            assert_raises(Interrupt) { appender.reopen }
          end

          assert_same socket, appender.socket
          assert_predicate interrupted, :closed?
        ensure
          appender.close
        end

        it "keeps its socket, and raises, when the server is a host name that does not resolve" do
          socket          = appender.socket
          appender.server = "logs.example:8088"

          not_resolving do
            assert_raises(SocketError) { appender.reopen }
          end

          assert_same socket, appender.socket
          refute_predicate socket, :closed?
        ensure
          appender.close
        end

        it "keeps its socket, and raises, when a new one cannot connect, closing the new one" do
          socket = appender.socket

          unreachable(Socket::AF_INET, Socket::AF_INET6) do |sockets|
            assert_raises(Errno::ENETUNREACH) { appender.reopen }
            refute_empty sockets
            assert(sockets.all?(&:closed?), "Left a socket that could not connect open")
          end

          assert_same socket, appender.socket
          refute_predicate socket, :closed?
        ensure
          appender.close
        end
      end

      describe "#message_error?" do
        it "is true for a log message too large to send as a datagram" do
          assert appender.message_error?(Errno::EMSGSIZE.new)
        end

        it "is false when the server is unavailable" do
          refute appender.message_error?(Errno::ECONNREFUSED.new)
        end
      end

      SemanticLogger::LEVELS.each do |level|
        it "send #{level}" do
          data = nil
          appender.socket.stub(:send, ->(d, _flags) { data = d }) do
            appender.send(level, amessage)
          end
          hash = JSON.parse(data)

          assert_equal amessage, hash["message"]
          assert_equal level.to_s, hash["level"]
          refute hash["stack_trace"]
        end

        it "send #{level} exceptions" do
          exc = nil
          begin
            Uh oh
          rescue Exception => e
            exc = e
          end
          data = nil
          appender.socket.stub(:send, ->(d, _flags) { data = d }) do
            appender.send(level, "Reading File", exc)
          end
          hash = JSON.parse(data)

          assert "Reading File", hash["message"]
          assert "NameError", hash["exception"]["name"]
          assert "undefined local variable or method", hash["exception"]["message"]
          assert_equal level.to_s, hash["level"], "Should be error level (3)"
          assert_includes hash["exception"]["stack_trace"].first, __FILE__, hash["exception"]
        end

        it "send #{level} custom attributes" do
          data = nil
          appender.socket.stub(:send, ->(d, _flags) { data = d }) do
            appender.send(level, amessage, key1: 1, key2: "a")
          end
          hash = JSON.parse(data)

          assert_equal amessage, hash["message"]
          assert_equal level.to_s, hash["level"]
          refute hash["stack_trace"]
          assert payload = hash["payload"], hash
          assert_equal 1, payload["key1"], payload
          assert_equal "a", payload["key2"], payload
        end
      end
    end
  end
end
