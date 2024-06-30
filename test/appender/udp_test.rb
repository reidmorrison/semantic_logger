require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Tcp
module Appender
  class UdpTest < Minitest::Test
    describe SemanticLogger::Appender::Udp do
      let(:appender) { SemanticLogger::Appender::Udp.new(server: "localhost:8088") }
      let(:amessage) { "AppenderUdpTest log message" }

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
          assert hash["exception"]["stack_trace"].first.include?(__FILE__), hash["exception"]
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
