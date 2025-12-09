require_relative "../test_helper"

add_mocks_to_load_path

require "semantic_logger/formatters/new_relic_logs"

require "date"

module SemanticLogger
  module Formatters
    class NewRelicLogsTest < Minitest::Test
      describe NewRelicLogs do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:level) do
          :debug
        end

        let(:appender) do
          SemanticLogger::Appender::NewRelicLogs.new
        end

        let(:log) do
          log      = SemanticLogger::Log.new("NewRelicLogsTest", level)
          log.time = log_time
          log
        end

        let(:formatted_log) do
          formatter = appender.formatter
          formatter.call(log, appender.logger)
        end

        let(:message_hash) do
          JSON.parse(formatted_log[:message]) if formatted_log[:message].is_a?(String)
        end

        describe "duration" do
          it "logs long duration" do
            log.duration = 1_000_000.34567
            result = formatted_log

            assert_equal 1_000_000.34567, result.dig(:duration, :ms)
            assert_equal "16m 40s", result.dig(:duration, :human)
          end

          it "logs short duration" do
            log.duration = 1.34567
            result = formatted_log

            # Expected human-readable duration based on precision
            expected_human_duration = SemanticLogger::Formatters::Base::PRECISION == 3 ? "1.346ms" : "1.346ms"

            # Verify the raw duration in milliseconds
            assert_equal 1.34567, result.dig(:duration, :ms)

            # Verify the human-readable duration format
            assert_equal expected_human_duration, result.dig(:duration, :human)
          end

          it "omits duration if not set" do
            result = formatted_log
            refute result.key?(:duration)
          end
        end

        describe "name" do
          it "logs name" do
            result = formatted_log
            assert_equal "NewRelicLogsTest", result.dig(:logger, :name)
          end
        end

        describe "message" do
          it "logs message" do
            log.message = "Hello World"
            result = formatted_log
            assert_equal "Hello World", result[:message]
          end

          it "keeps empty message" do
            log.message = ""
            result = formatted_log
            assert_equal "", result[:message]
          end
        end

        describe "payload" do
          it "logs hash payload" do
            log.payload = {first: 1, second: 2, third: 3}
            result = formatted_log
            assert_equal(
              {first: 1, second: 2, third: 3},
              result[:payload]
            )
          end

          it "skips nil payload" do
            log.payload = nil
            result = formatted_log
            refute result.key?(:payload)
          end

          it "skips empty payload" do
            log.payload = {}
            result = formatted_log
            refute result.key?(:payload)
          end
        end

        describe "tags and named_tags" do
          it "logs tags" do
            log.tags = %w[first second third]
            assert_equal %w[first second third], formatted_log[:tags]
          end

          it "logs named tags without conflicts" do
            log.named_tags = {first: 1, second: 2}
            result = formatted_log
            assert_equal 1, result[:first]
            assert_equal 2, result[:second]
            refute result.key?(:named_tag_conflicts)
          end

          it "logs named tag conflicts" do
            log.named_tags = {message: "conflict"}
            result = formatted_log
            assert_includes result[:named_tag_conflicts], :message
          end
        end

        describe "exceptions" do
          it "skips nil exception" do
            refute formatted_log.dig(:error, :message)
            refute formatted_log.dig(:error, :class)
            refute formatted_log.dig(:error, :stack)
          end

          it "logs exception details" do
            begin
              raise "Test Exception"
            rescue StandardError
              log.exception = $!
            end
            result = formatted_log
            assert_equal "Test Exception", result.dig(:error, :message)
            assert_equal "RuntimeError", result.dig(:error, :class)
            assert result.dig(:error, :stack).is_a?(String)
          end

          it "omits exception if not set" do
            result = formatted_log
            refute result.key?(:error)
          end
        end

        describe "general structure" do
          it "includes standard fields" do
            log.message = "Hello World"
            result = formatted_log
            assert_equal "Hello World", result[:message]
            assert_equal "NewRelicLogsTest", result.dig(:logger, :name)
            assert result[:timestamp].is_a?(Integer)
          end

          it "omits nil or empty fields" do
            result = formatted_log
            refute result.key?(:payload)
            refute result.key?(:tags)
          end
        end

        describe "metadata" do
          it "includes trace.id and span.id if present" do
            # Simulate recording a log message within a Rails transaction, where trace.id has been set on the current thread
            log.set_context(:new_relic_metadata, {"trace.id" => "trace123", "span.id" => "span456"})
            # ... which is then formatted on the async appender thread
            result = formatted_log
            assert_equal "trace123", result["trace.id"]
            assert_equal "span456", result["span.id"]
          end

          it "omits trace.id and span.id if absent" do
            result = formatted_log
            refute result.key?("trace.id")
            refute result.key?("span.id")
          end
        end
      end
    end
  end
end
