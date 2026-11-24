require_relative "../test_helper"
require_relative "../forked_child_helper"
require_relative "../tls_server"

# Unit Test for SemanticLogger::Appender::Tcp
module Appender
  class TcpTest < Minitest::Test
    describe SemanticLogger::Appender::Tcp do
      # A server that accepts connections, without reading what they send.
      def listener
        @listener ||= TCPServer.new("127.0.0.1", 0)
      end

      def appender
        @appender ||= SemanticLogger::Appender::Tcp.new(server: "127.0.0.1:#{listener.addr[1]}")
      end

      after do
        @appender&.close
        @listener&.close unless @listener&.closed?
      end

      let(:amessage) { "AppenderTcpTest log message" }

      describe "connection options" do
        it "hands them to its connection" do
          appender = SemanticLogger::Appender::Tcp.new(servers: ["127.0.0.1:#{listener.addr[1]}"], connect_timeout: 3)

          assert_equal ["127.0.0.1:#{listener.addr[1]}"], appender.tcp_client.servers
        ensure
          appender&.close
        end

        it "raises ArgumentError for an option of Net::TCPClient that it does not take" do
          error = assert_raises(ArgumentError) do
            SemanticLogger::Appender::Tcp.new(server: "127.0.0.1:#{listener.addr[1]}", retry_count: 2)
          end

          assert_includes error.message, "retry_count: it does not retry by itself"
        end

        it "reports, rather than raises, that it cannot connect as it is added, and connects at the next write" do
          port = listener.addr[1]
          listener.close
          internal_logger = SemanticLogger::Test::CaptureLogEvents.new
          appender        = SemanticLogger::Processor.stub(:logger, internal_logger) do
            SemanticLogger::Appender::Tcp.new(server: "127.0.0.1:#{port}")
          end
          report = internal_logger.events.last

          assert_equal :warn, report.level
          assert_equal "Could not connect: the next write connects, if it has no connection", report.message
          assert_instance_of SemanticLogger::Appender::TcpConnection::ConnectError, report.exception
          refute_predicate appender.tcp_client, :connected?
          lost = SemanticLogger::Log.new("TcpTest", :info)
          lost.message = "lost"
          assert_raises(SemanticLogger::Appender::TcpConnection::ConnectError) { appender.log(lost) }
        ensure
          appender&.close
        end
      end

      describe "#wrote_nothing? and #not_sent?" do
        it "are true when it could not connect, wrote_nothing? when nothing was sent, and false after part was" do
          connect_error = SemanticLogger::Appender::TcpConnection::ConnectError.new("refused")
          write_error   = SemanticLogger::Appender::TcpConnection::WriteError.new("reset")

          assert appender.wrote_nothing?(connect_error)
          assert appender.not_sent?(connect_error)
          refute appender.wrote_nothing?(write_error)
          refute appender.not_sent?(write_error)

          nothing_written = SemanticLogger::Appender::TcpConnection::NothingWritten.new("timed out")

          assert appender.wrote_nothing?(nothing_written)
          refute appender.not_sent?(nothing_written)
        end
      end

      SemanticLogger::LEVELS.each do |level|
        it "send #{level}" do
          data = nil
          appender.tcp_client.stub(:write, ->(d) { data = d }) do
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
          appender.tcp_client.stub(:write, ->(d) { data = d }) do
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
          appender.tcp_client.stub(:write, ->(d) { data = d }) do
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

      describe "over TLS, after a fork" do
        include ForkedChildHelper

        let(:server) { TlsServer.new }
        let(:tls_appender) do
          SemanticLogger::Appender::Tcp.new(
            server:    "127.0.0.1:#{server.port}",
            ssl:       {verify_mode: OpenSSL::SSL::VERIFY_NONE},
            formatter: ->(log, _logger) { log.message }
          )
        end

        after do
          tls_appender.close
          server.close
        end

        def log_with(message)
          log         = SemanticLogger::Log.new("Test", :info)
          log.message = message
          log
        end

        it "leaves the connection it inherited to the parent process, and connects again in the child" do
          tls_appender.log(log_with("before"))
          in_forked_child do
            tls_appender.reopen
            tls_appender.log(log_with("child"))
            ""
          end
          tls_appender.log(log_with("after"))

          assert_equal %w[before after], server.received(1, 2)
          assert_equal ["child", :closed], server.received(2, 2)
        end

        it "connects in the child when a reopen there cannot, rather than writing through the parent's connection" do
          tls_appender.log(log_with("before"))
          output = in_forked_child do
            internal_logger     = SemanticLogger::Test::CaptureLogEvents.new
            tls_appender.logger = internal_logger
            Socket.stub(:tcp, ->(*, **) { raise Errno::ECONNREFUSED }) { tls_appender.reopen }
            tls_appender.log(log_with("child"))
            internal_logger.events.last.exception.class.name
          end
          tls_appender.log(log_with("after"))

          assert_equal "SemanticLogger::Appender::TcpConnection::ConnectError", output
          assert_equal %w[before after], server.received(1, 2)
          assert_equal ["child", :closed], server.received(2, 2)
        end

        it "leaves the connection it inherited to the parent when it is closed in a child that has not reopened" do
          tls_appender.log(log_with("before"))
          in_forked_child do
            tls_appender.close
            tls_appender.log(log_with("child"))
            ""
          end
          tls_appender.log(log_with("after"))

          assert_equal %w[before after], server.received(1, 2)
          assert_equal ["child", :closed], server.received(2, 2)
        end
      end

      describe "over TCP, after a fork" do
        include ForkedChildHelper

        let(:server) { TCPServer.new("127.0.0.1", 0) }
        let(:tcp_appender) { SemanticLogger::Appender::Tcp.new(server: "127.0.0.1:#{server.addr[1]}") }

        after do
          server.close
        end

        it "closes its copy of the connection it inherited, so the server sees it end once the parent closes it" do
          tcp_appender
          inherited = server.accept
          ended     = while_forked_child_runs(-> { tcp_appender.reopen }) do
            tcp_appender.close
            inherited.wait_readable(2) && inherited.read_nonblock(1, exception: false).nil?
          end

          assert ended, "The server did not see the connection end while the child process was running"
        ensure
          inherited&.close
        end
      end
    end
  end
end
