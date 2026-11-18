require_relative "../test_helper"

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
    end
  end
end
