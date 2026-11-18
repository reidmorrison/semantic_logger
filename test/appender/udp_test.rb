require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Tcp
module Appender
  class UdpTest < Minitest::Test
    describe SemanticLogger::Appender::Udp do
      let(:appender) { SemanticLogger::Appender::Udp.new(server: "localhost:8088", metrics: true) }
      let(:amessage) { "AppenderUdpTest log message" }

      # Returns [true|false] whether the SocketError that Addrinfo.getaddrinfo raises has an #error_code, which says why
      # the lookup failed: Socket::ResolutionError has one from Ruby 3.3, and JRuby has neither.
      def error_codes?
        !defined?(Socket::ResolutionError).nil?
      end

      # Returns [SocketError] an error such as Addrinfo.getaddrinfo raises, given the name of the Socket constant of its
      # code, such as :EAI_NONAME. Where errors have codes (see #error_codes?), it has that #error_code, which cannot be
      # given to the constructor of Socket::ResolutionError.
      def resolution_error(code_name, reason)
        error = SocketError.new("getaddrinfo: #{reason}")
        if error_codes?
          code = Socket.const_get(code_name)
          error.define_singleton_method(:error_code) { code }
        end
        error
      end

      # Returns [SocketError] the error of a lookup that found no address, as of a name that does not resolve.
      def no_address_error
        resolution_error(:EAI_NONAME, "nodename nor servname provided, or not known")
      end

      # Returns [SocketError] the error of a lookup that failed, as when the resolver does not answer in time.
      def temporary_error
        resolution_error(:EAI_AGAIN, "Temporary failure in name resolution")
      end

      # Runs the block while Addrinfo.getaddrinfo resolves the name to those of the addresses in the family asked for,
      # in that order, rather than asking a resolver, and raises the error of a name without an address in that family
      # when there are none, or with empty: true returns none, as JRuby does. A family in failures raises its error
      # instead. Other names resolve as before. Yields the families asked for the name, in order.
      def resolving(name, *addresses, failures: {}, empty: false)
        getaddrinfo = Addrinfo.method(:getaddrinfo)
        asked       = []
        resolve     = lambda do |host, port, family = nil, *args|
          next getaddrinfo.call(host, port, family, *args) unless host == name

          asked << family
          raise(failures[family]) if failures.key?(family)

          found = addresses.map { |address| Addrinfo.udp(address, port) }
          found.select!(&:ipv4?) if family == :INET
          found.select!(&:ipv6?) if family == :INET6
          raise(no_address_error) if found.empty? && !empty

          found
        end
        Addrinfo.stub(:getaddrinfo, resolve) { yield(asked) }
      end

      # Runs the block while Addrinfo.getaddrinfo raises the error of a name that does not resolve, rather than asking a
      # resolver.
      def not_resolving(&)
        error = ->(*) { raise(no_address_error) }
        Addrinfo.stub(:getaddrinfo, error, &)
      end

      # Skips the test where IPv6 is not available, so that a socket for it cannot be created.
      def require_ipv6
        skip("IPv6 is not available") unless Socket.ip_address_list.any?(&:ipv6_loopback?)
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
          require_ipv6

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
          require_ipv6

          asked = nil
          entry = resolving("logs.example", "::1") do |families|
            asked = families
            received(Socket::AF_INET6, "::1") { |port| "logs.example:#{port}" }
          end

          assert_equal amessage, entry["message"]
          assert_equal %i[INET INET6], asked
        end

        it "sends over IPv6 to a host name with only IPv6 addresses when the IPv4 lookup returns none, as on JRuby" do
          require_ipv6

          entry = resolving("logs.example", "::1", empty: true) do
            received(Socket::AF_INET6, "::1") { |port| "logs.example:#{port}" }
          end

          assert_equal amessage, entry["message"]
        end

        it "sends over IPv4 to a host name that has both, whichever the resolver returns first, as before" do
          asked = nil
          entry = resolving("logs.example", "::1", "127.0.0.1") do |families|
            asked = families
            received(Socket::AF_INET, "127.0.0.1") { |port| "logs.example:#{port}" }
          end

          assert_equal amessage, entry["message"]
          assert_equal %i[INET], asked, "Looked up the IPv6 addresses, which it did not need"
        end

        it "sends over IPv6 to a host name that has both when it cannot connect over IPv4" do
          require_ipv6

          entry = resolving("logs.example", "127.0.0.1", "::1") do
            unreachable(Socket::AF_INET) do
              received(Socket::AF_INET6, "::1") { |port| "logs.example:#{port}" }
            end
          end

          assert_equal amessage, entry["message"]
        end

        it "raises the error from the first address when it cannot connect to any, closing each socket" do
          require_ipv6

          resolving("logs.example", "127.0.0.1", "::1") do
            unreachable(Socket::AF_INET, Socket::AF_INET6) do |sockets|
              error = assert_raises(Errno::ENETUNREACH) do
                SemanticLogger::Appender::Udp.new(server: "logs.example:8088", metrics: false)
              end

              assert_includes error.message, "family #{Socket::AF_INET}"
              assert_equal(2, sockets.count(&:closed?))
            end
          end
        end

        it "raises the error from connecting to a host name that has only IPv6 addresses when it cannot connect" do
          require_ipv6

          resolving("logs.example", "::1") do
            unreachable(Socket::AF_INET6) do
              error = assert_raises(Errno::ENETUNREACH) do
                SemanticLogger::Appender::Udp.new(server: "logs.example:8088", metrics: false)
              end

              assert_includes error.message, "family #{Socket::AF_INET6}"
            end
          end
        end

        # Sending over IPv6 to a name that has IPv4 addresses after one failed lookup, such as in the reopen after a
        # fork, or waiting for a resolver that is down a second time.
        it "raises a failure to look up a host name's IPv4 addresses at once, rather than looking up its IPv6 ones" do
          skip("SocketError does not say why a lookup failed") unless error_codes?

          asked = nil
          error = resolving("logs.example", "127.0.0.1", "::1", failures: {INET: temporary_error}) do |families|
            asked = families
            assert_raises(SocketError) { SemanticLogger::Appender::Udp.new(server: "logs.example:8088", metrics: false) }
          end

          assert_equal "getaddrinfo: Temporary failure in name resolution", error.message
          assert_equal %i[INET], asked
        end

        it "raises a failure to look up the IPv6 addresses of a host name without IPv4 ones, caused by their absence" do
          asked = nil
          error = resolving("logs.example", failures: {INET6: temporary_error}) do |families|
            asked = families
            assert_raises(SocketError) { SemanticLogger::Appender::Udp.new(server: "logs.example:8088", metrics: false) }
          end

          assert_equal "getaddrinfo: Temporary failure in name resolution", error.message
          assert_equal "getaddrinfo: nodename nor servname provided, or not known", error.cause&.message
          assert_equal %i[INET INET6], asked
        end

        # Socket::ResolutionError#error_code, which tells them apart, is new in Ruby 3.3.
        it "looks up the IPv6 addresses after any failure to look up the IPv4 ones without an error code, as before" do
          asked  = nil
          failed = SocketError.new("getaddrinfo: Temporary failure in name resolution")
          error  = resolving("logs.example", failures: {INET: failed}) do |families|
            asked = families
            assert_raises(SocketError) { SemanticLogger::Appender::Udp.new(server: "logs.example:8088", metrics: false) }
          end

          assert_equal %i[INET INET6], asked
          assert_same failed, error.cause
        end

        it "raises SocketError naming a host name that has no address when no lookup raises, as on JRuby" do
          asked = nil
          error = resolving("logs.example", empty: true) do |families|
            asked = families
            assert_raises(SocketError) { SemanticLogger::Appender::Udp.new(server: "logs.example:8088", metrics: false) }
          end

          assert_equal "getaddrinfo: no address for logs.example", error.message
          assert_equal %i[INET INET6], asked
        end

        it "raises SocketError, as before, for a host name that does not resolve" do
          not_resolving do
            assert_raises(SocketError) do
              SemanticLogger::Appender::Udp.new(server: "logs.example:8088", metrics: false)
            end
          end
        end

        it "ignores whitespace after the server, such as an environment variable's newline, as before" do
          entry = received(Socket::AF_INET, "127.0.0.1") { |port| "localhost:#{port} \n" }

          assert_equal amessage, entry["message"]
        end

        # An address in brackets is looked up as an IPv6 address only, which asks no resolver.
        it "raises SocketError for an IPv4 address in brackets" do
          assert_raises(SocketError) do
            SemanticLogger::Appender::Udp.new(server: "[127.0.0.1]:8088", metrics: false)
          end
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
          socket          = appender.socket
          appender.server = "logs.example:8088"

          resolving("logs.example", "127.0.0.1") do
            unreachable(Socket::AF_INET) do |sockets|
              assert_raises(Errno::ENETUNREACH) { appender.reopen }
              assert_equal 1, sockets.size
              assert_predicate sockets.first, :closed?, "Left a socket that could not connect open"
            end
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
