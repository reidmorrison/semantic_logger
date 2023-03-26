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

        let(:expected_time) do
          1_484_382_725_375
        end

        let(:set_exception) do
          raise "Oh no"
        rescue Exception => e
          log.exception = e
        end

        let(:expected_exception_backtrace) do
          log.exception.backtrace.join("\n")
        end

        let(:backtrace) do
          [
            "test/formatters/default_test.rb:99:in `block (2 levels) in <class:DefaultTest>'",
            "gems/ruby-2.3.3/gems/minitest-5.10.1/lib/minitest/spec.rb:247:in `instance_eval'",
            "gems/ruby-2.3.3/gems/minitest-5.10.1/lib/minitest/spec.rb:247:in `block (2 levels) in let'",
            "gems/ruby-2.3.3/gems/minitest-5.10.1/lib/minitest/spec.rb:247:in `fetch'",
            "ruby-2.3.3/gems/minitest-5.10.1/lib/minitest/spec.rb:247:in `block in let'",
            "test/formatters/default_test.rb:65:in `block (3 levels) in <class:DefaultTest>'",
            "ruby-2.3.3/gems/minitest-5.10.1/lib/minitest/test.rb:105:in `block (3 levels) in run'"
          ]
        end

        let(:formatted_log) do
          formatter = appender.formatter
          formatter.call(log, appender.logger)
        end

        let(:message_hash) do
          JSON.parse(formatted_log[:message])
        end

        describe "time" do
          it "logs time" do
            assert_equal expected_time, formatted_log[:timestamp]
          end
        end

        describe "level" do
          it "logs long name" do
            assert_equal "DEBUG", formatted_log[:"log.level"]
          end
        end

        describe "process_info" do
          it "logs thread name" do
            assert_equal Thread.current.name, formatted_log[:"thread.name"]
          end

          it "logs pid, thread name, and file name" do
            set_exception
            log.backtrace = backtrace
            assert_equal Thread.current.name, formatted_log[:"thread.name"]
            assert_equal "test/formatters/default_test.rb", formatted_log[:"file.name"]
            assert_equal "99", formatted_log[:"line.number"]
          end
        end

        describe "tags" do
          it "logs tags" do
            log.tags = %w[first second third]
            assert_equal log.tags, message_hash["tags"]
          end
        end

        describe "named_tags" do
          it "logs named tags" do
            log.named_tags = {first: 1, second: 2, third: 3}
            assert_equal(
              {"first" => 1, "second" => 2, "third" => 3},
              message_hash["named_tags"]
            )
          end
        end

        describe "duration" do
          it "logs long duration" do
            log.duration = 1_000_000.34567
            assert_equal log.duration, message_hash["duration"]
          end

          it "logs short duration" do
            log.duration = 1.34567
            duration     = SemanticLogger::Formatters::Base::PRECISION == 3 ? "1ms" : "1.346ms"

            assert_equal duration, message_hash["duration_human"]
            assert_equal log.duration, message_hash["duration"]
          end
        end

        describe "name" do
          it "logs name" do
            assert_equal "NewRelicLogsTest", formatted_log[:"logger.name"]
          end
        end

        describe "message" do
          it "logs message" do
            log.message = "Hello World"
            assert_equal "Hello World", message_hash["message"]
          end

          it "keeps empty message" do
            assert_equal "", message_hash["message"]
          end
        end

        describe "payload" do
          it "logs hash payload" do
            log.payload = {first: 1, second: 2, third: 3}
            assert_equal(
              {"first" => 1, "second" => 2, "third" => 3},
              message_hash["payload"]
            )
          end

          it "skips nil payload" do
            refute message_hash["payload"]
          end

          it "skips empty payload" do
            log.payload = {}
            refute message_hash["payload"]
          end
        end

        describe "exception" do
          it "skips nil exception" do
            refute formatted_log[:"error.message"]
            refute formatted_log[:"error.class"]
            refute formatted_log[:"error.stack"]
          end
        end

        describe "call" do
          it "retuns all elements" do
            log.tags       = %w[first second third]
            log.named_tags = {first: 1, second: 2, third: 3}
            log.duration   = 1.34567
            log.message    = "Hello World"
            log.payload    = {first: 1, second: 2, third: 3}
            log.backtrace  = backtrace
            set_exception
            duration = SemanticLogger::Formatters::Base::PRECISION == 3 ? "1" : "1.346"

            expected_hash = {
              "entity.name":   "Entity Name",
              "entity.type":   "SERVICE",
              hostname:        "hostname",
              message:         "{\"message\":\"Hello World\",\"tags\":[\"first\",\"second\",\"third\"],\"named_tags\":{\"first\":1,\"second\":2,\"third\":3},\"environment\":\"test\",\"application\":\"Semantic Logger\",\"payload\":{\"first\":1,\"second\":2,\"third\":3},\"duration\":1.34567,\"duration_human\":\"1.346ms\"}",
              timestamp:       1_484_382_725_375,
              "log.level":     "DEBUG",
              "logger.name":   "NewRelicLogsTest",
              "thread.name":   Thread.current.name,
              "error.message": "Oh no",
              "error.class":   "RuntimeError",
              "error.stack":   expected_exception_backtrace,
              "file.name":     "test/formatters/default_test.rb",
              "line.number":   "99"
            }

            assert_equal expected_hash, formatted_log
          end
        end
      end
    end
  end
end
