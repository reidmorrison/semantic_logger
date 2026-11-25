require_relative "../test_helper"
require_relative "../forked_child_helper"
require_relative "../tls_server"

# Unit Test for SemanticLogger::Appender::Tcp
module Appender
  class TcpTest < Minitest::Test
    describe SemanticLogger::Appender::Tcp do
      let(:appender) do
        appender =
          Net::TCPClient.stub_any_instance(:connect, true) do
            SemanticLogger::Appender::Tcp.new(server: "localhost:8088")
          end
        appender.tcp_client.instance_eval do
          def retry_on_connection_failure
            yield
          end
        end
        appender
      end

      let(:amessage) { "AppenderTcpTest log message" }

      describe "options that v6 does not take" do
        def appender_with(**options)
          Net::TCPClient.stub_any_instance(:connect, true) do
            SemanticLogger::Appender::Tcp.new(server: "localhost:8088", **options)
          end
        end

        it "warns naming each one, with why" do
          names  = "The :tcp appender's connect_retry_count:, retry_count:, read_timeout: are deprecated, " \
                   "and v6 raises ArgumentError for them"
          reason = "retry_count: v6 does not retry by itself"
          assert_deprecated(/#{Regexp.escape(names)}.*#{Regexp.escape(reason)}/) do
            appender_with(connect_retry_count: 1, retry_count: 1, read_timeout: 2)
          end
        end

        it "warns for a Proc policy" do
          assert_deprecated(/policy: is deprecated.*not a Proc/) { appender_with(policy: ->(servers) { servers }) }
        end

        it "says to set the retry counts to 0, which v6 takes" do
          assert_deprecated(/does not retry by itself, so it takes only connect_retry_count: 0 and retry_count: 0/) do
            appender_with(retry_count: 3)
          end
        end

        it "warns for connect_retry_interval: without connect_retry_count: 0" do
          assert_deprecated(/connect_retry_interval: is deprecated/) { appender_with(connect_retry_interval: 0.1) }
        end

        it "does not warn for the options that v6 keeps, the values that it takes, or an option given as nil" do
          refute_deprecated do
            appender_with(connect_timeout: 3, write_timeout: 4, keepalive: true, policy: :ordered, ssl: nil,
                          read_timeout: nil, connect_retry_count: 0, connect_retry_interval: 0.1, retry_count: 0,
                          buffered: false)
          end
        end
      end

      describe "net_tcp_client older than 2.3" do
        let(:options) { SemanticLogger::Appender::TcpClientOptions }

        it "warns that it calls the deprecated benchmark_* methods, and to update it" do
          warning = /:tcp appender uses net_tcp_client 2\.2\.1, which calls the deprecated benchmark_\* .*to 2\.3\.0/
          outdated = assert_deprecated(warning) { options.report_outdated_gem(":tcp", "2.2.1") }

          assert outdated
        end

        it "does not warn for 2.3 or later" do
          refute_deprecated do
            refute options.report_outdated_gem(":tcp", "2.3.0")
            refute options.report_outdated_gem(":tcp", "2.10.0")
          end
        end

        it "gives benchmark_* methods that do not warn to a logger extended with BenchmarkWithoutWarning" do
          logger = SemanticLogger::Test::CaptureLogEvents.new.extend(options::BenchmarkWithoutWarning)
          result = refute_deprecated { logger.benchmark_debug("#write") { "written" } }

          assert_equal "written", result
          assert_equal "#write", logger.events.last.message
          assert logger.events.last.duration
        end

        it "extends the appender's own logger, which it gives net_tcp_client, when it is outdated" do
          built = options.stub(:report_outdated_gem, ->(name) { name == ":tcp" }) { appender }

          assert_same built.logger, Net::TCPClient.logger
          assert_kind_of options::BenchmarkWithoutWarning, built.logger
        ensure
          Net::TCPClient.logger = nil
        end

        it "leaves the appender's logger as it is with 2.3 or later" do
          built = options.stub(:report_outdated_gem, false) { appender }

          refute_kind_of options::BenchmarkWithoutWarning, built.logger
        ensure
          Net::TCPClient.logger = nil
        end
      end

      describe "ssl:" do
        # Returns [SemanticLogger::Appender::Tcp] an appender built with the given ssl: option, which connects to
        # nothing.
        def appender_with(ssl)
          Net::TCPClient.stub_any_instance(:connect, true) do
            SemanticLogger::Appender::Tcp.new(server: "localhost:8088", ssl: ssl)
          end
        end

        it "keeps the handshake_timeout after a reopen, and leaves the Hash given as it is" do
          ssl      = {handshake_timeout: 2, ca_file: "ca.pem"}
          appender = appender_with(ssl)

          assert_in_delta 2.0, appender.tcp_client.ssl_handshake_timeout

          Net::TCPClient.stub_any_instance(:connect, true) { appender.reopen }

          assert_in_delta 2.0, appender.tcp_client.ssl_handshake_timeout
          assert_equal({handshake_timeout: 2, ca_file: "ca.pem"}, ssl)
        end

        it "accepts a frozen Hash" do
          [{handshake_timeout: 2}.freeze, {ca_file: "ca.pem"}.freeze].each do |ssl|
            appender = appender_with(ssl)

            assert_in_delta ssl.fetch(:handshake_timeout, 10.0), appender.tcp_client.ssl_handshake_timeout
          end
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
            error = Net::TCPClient.stub(:new, ->(**) { raise Errno::ECONNREFUSED }) do
              tls_appender.reopen
            rescue Errno::ECONNREFUSED => e
              e
            end
            tls_appender.log(log_with("child"))
            error.class.name
          end
          tls_appender.log(log_with("after"))

          assert_equal "Errno::ECONNREFUSED", output
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
