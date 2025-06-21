require_relative "../test_helper"
require "json"

module SemanticLogger
  module Formatters
    class LokiTest < Minitest::Test
      MOCK_LOGGER = Struct.new(:host, :application, :name, :environment)

      describe SemanticLogger::Formatters::Loki do
        let(:log_time) { Time.utc(2017, 1, 14, 8, 32, 5.375276) }
        let(:level) { :debug }
        let(:thread_name) { "thread-#{Thread.current.object_id}" }

        let(:log) do
          l = SemanticLogger::Log.new("LokiTest", level)
          l.time = log_time
          l.thread_name = thread_name
          l.message = "initial message"
          l
        end

        let(:set_exception) do
          raise "Oh no"
        rescue RuntimeError => e
          log.exception = e
        end

        let(:logger) do
          MOCK_LOGGER.new("test_host", "test_app", "TestLogger", "test")
        end

        let(:appender) do
          SemanticLogger::Metric::Loki.new(url: "https://example.com")
        end

        let(:formatter) do
          appender.formatter
        end

        let(:parsed_output) { JSON.parse(formatter.call(log, logger)) }
        let(:stream_data) { parsed_output["streams"].first["stream"] }
        let(:values_data) { parsed_output["streams"].first["values"].first }

        describe "#call" do
          it "returns a JSON string" do
            assert_kind_of String, formatter.call(log, logger)
          end

          it "has the correct streams structure" do
            assert parsed_output.key?("streams")
            assert_kind_of Array, parsed_output["streams"]
            assert_equal 1, parsed_output["streams"].size
            assert parsed_output["streams"].first.key?("stream")
            assert parsed_output["streams"].first.key?("values")
          end

          it "includes pid in stream" do
            assert_equal Process.pid, stream_data["pid"]
          end

          it "includes host in stream as string" do
            assert_equal "test_host", stream_data["host"]
          end

          it "includes application in stream" do
            assert_equal "test_app", stream_data["application"]
          end

          it "includes environment in stream" do
            assert_equal "test", stream_data["environment"]
          end

          it "includes level in stream" do
            assert_equal "debug", stream_data["level"]
          end

          it "includes thread_name in stream if present" do
            assert_equal thread_name, stream_data["thread"]
          end

          it "includes timestamp in values as nanoseconds string" do
            assert_equal "1484382725375276000", values_data[0]
          end

          it "includes the message" do
            assert_equal "initial message", values_data[1]
          end

          it "includes payload in values as the third element (hash)" do
            log.payload = {data: "sample", number: 123, array: [1, 2, 3]}
            assert_equal(
              {"data" => "sample", "number" => "123", "array" => "[1, 2, 3]"},
              values_data[2]
            )
          end

          it "serializes nested hashes in the payload as JSON" do
            log.payload = {nested: {number: 1}}
            assert_equal({"nested" => "{\"number\":\"1\"}"}, values_data[2])
          end

          describe "when log application is true" do
            let(:formatter) do
              Loki.new(log_application: false)
            end

            it "omits application in stream when log_application is false" do
              refute parsed_output["streams"].first["stream"].key?("application")
            end
          end

          describe "when logger.application is nil" do
            let(:formatter) { Loki.new(log_application: false) }
            let(:logger) { MOCK_LOGGER.new("test_host", nil, "TestLogger", "test") }

            it "omits application in stream when log_application is false" do
              refute parsed_output["streams"].first["stream"].key?("application")
            end
          end

          describe "when thread_name is nil" do
            it "omits from the stream" do
              log.thread_name = nil

              refute stream_data.key?("thread")
            end
          end

          describe "when tags is present" do
            it "adds to the stream" do
              log.tags = [:test1, "test2"]

              assert_equal ["test1", "test2"], stream_data["tags"]
            end
          end

          describe "when tags is nil" do
            it "omits from the steam" do
              log.tags = nil

              refute stream_data.key?("tags")
            end
          end

          describe "when named_tags is present" do
            it "adds to the stream" do
              log.named_tags = {key1: "value1", key2: "value2"}

              assert_equal "value1", stream_data["key1"]
              assert_equal "value2", stream_data["key2"]
            end
          end

          describe "when named_tags is nil" do
            it "omits from the stream" do
              log.named_tags = nil

              refute stream_data.key?("key1")
              refute stream_data.key?("key2")
            end
          end

          describe "when named_tags is empty" do
            it "omits from the stream" do
              log.named_tags = {}

              refute stream_data.key?("key1")
              refute stream_data.key?("key2")
            end
          end

          describe "when message is nil" do
            it "includes empty string for message" do
              log.message = nil
              assert_equal "", values_data[1]
            end
          end

          describe "when payload is nil" do
            it "includes empty hash for payload" do
              log.payload = nil
              assert_equal({}, values_data[2])
            end
          end

          describe "when payload is empty hash" do
            it "includes empty hash for payload" do
              log.payload = {}
              assert_equal({}, values_data[2])
            end
          end

          describe "when context is present" do
            it "includes empty hash for payload" do
              log.context = {test: "string", hash: {value: "1"}}

              assert_equal "string", stream_data["test"]
              assert_equal "{\"value\":\"1\"}", stream_data["hash"]
            end
          end

          describe "when context is empty" do
            it "keeps the existing keys on the stream" do
              log.context = {}

              expected_keys = %w[
                pid
                application
                environment
                host
                level
                thread
              ]
              assert_equal(expected_keys, stream_data.keys)
            end
          end

          describe "when context is nil" do
            it "keeps the existing keys on the stream" do
              log.context = nil

              expected_keys = %w[
                pid
                application
                environment
                host
                level
                thread
              ]
              assert_equal(expected_keys, stream_data.keys)
            end
          end

          it "includes metric in payload part of values if present" do
            log.metric = "my_metric"
            log.metric_amount = 100

            payload_obj = values_data[2]
            assert_equal "my_metric", payload_obj["metric"]
            assert_equal 100, payload_obj["metric_value"]
          end

          it "merges metric with existing payload" do
            log.payload = {data: "sample"}
            log.metric = "my_metric"
            log.metric_amount = 100

            payload_obj = values_data[2]
            assert_equal "sample", payload_obj["data"]
            assert_equal "my_metric", payload_obj["metric"]
            assert_equal 100, payload_obj["metric_value"]
          end

          describe "when duration is present" do
            it "includes duration" do
              log.duration = 123.456
              log.stub(:duration_human, "123.46ms") do
                payload_obj = values_data[2]
                assert_equal "123.456", payload_obj["duration"]
                assert_equal "123.46ms", payload_obj["duration_human"]
              end
            end
          end

          describe "when duration is nil" do
            it "omits duration and duration_human" do
              log.duration = nil
              payload_obj = values_data[2]

              refute payload_obj.key?("duration")
              refute payload_obj.key?("duration_human")
            end
          end

          it "includes exception in payload part of values if present" do
            set_exception

            payload_obj = values_data[2]
            assert_equal "RuntimeError", payload_obj["exception_name"]
            assert_equal "Oh no", payload_obj["exception_message"]
            assert_kind_of String, payload_obj["stack_trace"]
          end

          it "merges exception with existing payload and metric" do
            log.payload = {data: "sample"}
            log.metric = "my_metric"
            log.metric_amount = 100
            set_exception

            payload_obj = values_data[2]

            assert_equal "sample", payload_obj["data"]
            assert_equal "my_metric", payload_obj["metric"]
            assert_equal 100, payload_obj["metric_value"]
            assert_equal "RuntimeError", payload_obj["exception_name"]
          end
        end

        describe "#batch" do
          let(:log2) do
            l = SemanticLogger::Log.new("LokiTest2", :info)
            l.time = log_time + 10 # Different time
            l.thread_name = "other-thread"
            l.message = "Second message"
            l
          end
          let(:logs) { [log, log2] }
          let(:parsed_batch_output) { JSON.parse(formatter.batch(logs, logger)) }

          it "returns a JSON string" do
            assert_kind_of String, formatter.batch(logs, logger)
          end

          it "has the correct streams structure for batch" do
            assert parsed_batch_output.key?("streams")
            assert_kind_of Array, parsed_batch_output["streams"]
            assert_equal 2, parsed_batch_output["streams"].size
          end

          it "formats each log entry correctly in batch" do
            stream1_data = parsed_batch_output["streams"][0]["stream"]
            values1_data = parsed_batch_output["streams"][0]["values"][0]
            stream2_data = parsed_batch_output["streams"][1]["stream"]
            values2_data = parsed_batch_output["streams"][1]["values"][0]

            assert_equal Process.pid, stream1_data["pid"]
            assert_equal "debug", stream1_data["level"]
            assert_equal thread_name, stream1_data["thread"]
            assert_equal "1484382725375276000", values1_data[0]
            assert_equal "initial message", values1_data[1]

            assert_equal Process.pid, stream2_data["pid"]
            assert_equal "info", stream2_data["level"]
            assert_equal "other-thread", stream2_data["thread"]
            assert_equal "1484382735375276000", values2_data[0]
            assert_equal "Second message", values2_data[1]
          end
        end
      end
    end
  end
end
