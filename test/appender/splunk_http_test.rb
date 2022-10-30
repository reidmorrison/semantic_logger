require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::SplunkHttp
module Appender
  class SplunkHttpTest < Minitest::Test
    response_mock = Struct.new(:code, :body)

    describe SemanticLogger::Appender::SplunkHttp do
      let(:appender) do
        Net::HTTP.stub_any_instance(:start, true) do
          SemanticLogger::Appender::SplunkHttp.new(
            url:   "http://localhost:8088/path",
            token: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
          )
        end
      end
      let(:amessage) { "AppenderSplunkHttpTest log message" }

      SemanticLogger::LEVELS.each do |level|
        it "send #{level}" do
          request = nil
          appender.http.stub(:request, ->(r) { request = r; response_mock.new("200", "ok") }) do
            appender.send(level, amessage)
          end
          body    = decompress_data(request.body)
          message = JSON.parse(body)
          assert_equal amessage, message["event"]["message"]
          assert_equal level.to_s, message["event"]["level"]
          refute message["event"]["exception"]
        end

        it "sends #{level} exceptions" do
          exc     = nil
          begin
            Uh oh
          rescue Exception => e
            exc = e
          end
          request = nil
          appender.http.stub(:request, ->(r) { request = r; response_mock.new("200", "ok") }) do
            appender.send(level, "Reading File", exc)
          end
          body = decompress_data(request.body)
          hash = JSON.parse(body)
          assert "Reading File", hash["message"]
          assert exception = hash["event"]["exception"]
          assert "NameError", exception["name"]
          assert "undefined local variable or method", exception["message"]
          assert_equal level.to_s, hash["event"]["level"]
          assert exception["stack_trace"].first.include?(__FILE__), exception
        end

        it "sends #{level} custom attributes" do
          request = nil
          appender.http.stub(:request, ->(r) { request = r; response_mock.new("200", "ok") }) do
            appender.send(level, amessage, key1: 1, key2: "a")
          end
          body    = decompress_data(request.body)
          message = JSON.parse(body)
          assert event = message["event"], message.ai
          refute_includes message["event"], "host"
          assert_equal amessage, event["message"]
          assert_equal level.to_s, event["level"]
          refute event["stack_trace"]
          assert payload = event["payload"], event
          assert_equal(1, payload["key1"], message)
          assert_equal("a", payload["key2"], message)
        end
      end

      def decompress_data(data)
        str = StringIO.new(data)
        gz  = Zlib::GzipReader.new(str)
        raw = gz.read
        gz.close
        raw
      end
    end
  end
end
