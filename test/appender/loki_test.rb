require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Loki
module Appender
  class LokiTest < Minitest::Test
    describe SemanticLogger::Appender::Loki do
      let(:http_success) { Net::HTTPSuccess.new("1.1", "200", "OK") }
      let(:log_message) { "AppenderLokiTest log message" }

      let(:appender) do
        Net::HTTP.stub_any_instance(:start, true) do
          SemanticLogger::Appender::Loki.new(url: "http://localhost:3100")
        end
      end

      describe "#initialize" do
        it "appends the Loki ingestion path to the url" do
          assert_equal "/#{SemanticLogger::Appender::Loki::INGESTION_PATH}", appender.path
          assert_equal "http://localhost:3100/#{SemanticLogger::Appender::Loki::INGESTION_PATH}", appender.url
        end

        it "allows a custom ingestion path" do
          custom = Net::HTTP.stub_any_instance(:start, true) do
            SemanticLogger::Appender::Loki.new(url: "http://localhost:3100", path: "custom/push")
          end

          assert_equal "/custom/push", custom.path
        end

        it "uses the Loki formatter by default" do
          assert_instance_of SemanticLogger::Formatters::Loki, appender.formatter
        end

        it "sets the JSON content type header" do
          assert_equal "application/json", appender.header["Content-Type"]
        end
      end

      SemanticLogger::LEVELS.each do |level|
        it "send #{level}" do
          request = nil
          appender.http.stub(:request, lambda { |r|
            request = r
            http_success
          }) do
            appender.send(level, log_message)
          end
          stream = JSON.parse(request.body)["streams"].first

          assert_equal level.to_s, stream["stream"]["level"]
          assert_equal log_message, stream["values"].first[1]
        end

        it "send #{level} exceptions" do
          exc = nil
          begin
            Uh oh
          rescue Exception => e
            exc = e
          end
          request = nil
          appender.http.stub(:request, lambda { |r|
            request = r
            http_success
          }) do
            appender.send(level, "Reading File", exc)
          end
          stream  = JSON.parse(request.body)["streams"].first
          payload = stream["values"].first[2]

          assert_equal level.to_s, stream["stream"]["level"]
          assert_equal "NameError", payload["exception_name"]
          assert_match(/undefined local variable or method/, payload["exception_message"])
          assert_includes payload["stack_trace"], __FILE__
        end

        it "send #{level} custom attributes" do
          request = nil
          appender.http.stub(:request, lambda { |r|
            request = r
            http_success
          }) do
            appender.send(level, log_message, key1: 1, key2: "a")
          end
          stream = JSON.parse(request.body)["streams"].first

          assert_equal level.to_s, stream["stream"]["level"]
          assert_equal log_message, stream["values"].first[1]

          # Loki only accepts strings as payload keys and values.
          payload = stream["values"].first[2]

          assert_equal "1", payload["key1"], payload
          assert_equal "a", payload["key2"], payload
        end
      end

      describe "#batch" do
        it "posts multiple log streams in a single request" do
          logs = [
            SemanticLogger::Log.new("LokiTest", :info),
            SemanticLogger::Log.new("LokiTest", :error)
          ]
          logs[0].message = "first"
          logs[1].message = "second"

          request = nil
          appender.http.stub(:request, lambda { |r|
            request = r
            http_success
          }) do
            appender.batch(logs)
          end

          streams = JSON.parse(request.body)["streams"]

          assert_equal 2, streams.size
          assert_equal "info",   streams[0]["stream"]["level"]
          assert_equal "first",  streams[0]["values"].first[1]
          assert_equal "error",  streams[1]["stream"]["level"]
          assert_equal "second", streams[1]["values"].first[1]
        end
      end
    end
  end
end
