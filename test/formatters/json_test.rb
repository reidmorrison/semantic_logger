require_relative "../test_helper"

module SemanticLogger
  module Formatters
    class JsonTest < Minitest::Test
      describe Json do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:level) do
          :debug
        end

        let(:log) do
          log      = SemanticLogger::Log.new("JsonTest", level)
          log.time = log_time
          log
        end

        let(:appender) do
          Struct.new(:host, :application, :environment).new("test_host", "test_app", "test_env")
        end

        let(:formatter) do
          SemanticLogger::Formatters::Json.new
        end

        let(:parsed) do
          JSON.parse(formatter.call(log, appender))
        end

        it "returns a JSON string" do
          result = formatter.call(log, appender)

          assert_kind_of String, result
          assert JSON.parse(result)
        end

        it "uses :timestamp as the default time key" do
          assert parsed.key?("timestamp")
          refute parsed.key?("time")
        end

        it "formats the time as iso_8601 by default" do
          assert_equal "2017-01-14T08:32:05.375276Z", parsed["timestamp"]
        end

        it "honours a custom time_key" do
          formatter = SemanticLogger::Formatters::Json.new(time_key: :ts)
          parsed    = JSON.parse(formatter.call(log, appender))

          assert parsed.key?("ts")
          refute parsed.key?("timestamp")
        end

        it "honours a custom time_format" do
          formatter = SemanticLogger::Formatters::Json.new(time_format: "%Y-%m-%d")
          parsed    = JSON.parse(formatter.call(log, appender))

          assert_equal "2017-01-14", parsed["timestamp"]
        end

        it "serializes the standard fields" do
          log.message    = "Hello World"
          log.payload    = {first: 1, second: 2}
          log.tags       = %w[first second]
          log.named_tags = {user: "joe"}

          assert_equal "debug",          parsed["level"]
          assert_equal log.level_index,  parsed["level_index"]
          assert_equal "JsonTest",       parsed["name"]
          assert_equal "Hello World",    parsed["message"]
          assert_equal $$,               parsed["pid"]
          assert_equal({"first" => 1, "second" => 2}, parsed["payload"])
          assert_equal %w[first second], parsed["tags"]
          assert_equal({"user" => "joe"}, parsed["named_tags"])
        end

        it "serializes an exception" do
          begin
            raise "Oh no"
          rescue Exception => e
            log.exception = e
          end

          assert_equal "RuntimeError", parsed["exception"]["name"]
          assert_equal "Oh no",        parsed["exception"]["message"]
        end

        # Issue #180: previously `.to_json` raised on non UTF-8 data (the exact class
        # varies by json gem version) and the log entry was dropped. Every field that
        # can carry caller-supplied strings must now serialize without raising.
        describe "non-UTF-8 data (issue #180)" do
          # A binary string holding a byte (0xE2) that is not valid UTF-8.
          let(:bad) { "Bad: \xE2".b }

          it "serializes host, application, and environment" do
            appender = Struct.new(:host, :application, :environment).new("host\xE2".b, "app\xE2".b, "env\xE2".b)
            parsed   = JSON.parse(formatter.call(log, appender))

            assert_equal "host", parsed["host"]
            assert_equal "app",  parsed["application"]
            assert_equal "env",  parsed["environment"]
          end

          it "serializes the name" do
            log.name = bad

            assert_equal "Bad: ", parsed["name"]
          end

          it "serializes the thread name" do
            log.thread_name = bad

            assert_equal "Bad: ", parsed["thread"]
          end

          it "serializes the message" do
            log.message = bad

            assert_equal "Bad: ", parsed["message"]
          end

          it "serializes the metric name" do
            log.metric        = bad
            log.metric_amount = 3

            assert_equal "Bad: ", parsed["metric"]
            assert_equal 3, parsed["metric_amount"]
          end

          it "serializes tags" do
            log.tags = ["good", bad]

            assert_equal ["good", "Bad: "], parsed["tags"]
          end

          it "serializes named_tag keys and values" do
            log.named_tags = {"key\xE2".b => bad}

            assert_equal({"key" => "Bad: "}, parsed["named_tags"])
          end

          it "serializes a nested payload, including keys and arrays" do
            log.payload = {"outer\xE2".b => {inner: bad, list: [bad]}}

            assert_equal({"outer" => {"inner" => "Bad: ", "list" => ["Bad: "]}}, parsed["payload"])
          end

          it "serializes the exception message and backtrace" do
            exception = RuntimeError.new(bad)
            exception.set_backtrace(["good_file.rb:1", "bad_file\xE2.rb:2".b])
            log.exception = exception

            assert_equal "Bad: ", parsed["exception"]["message"]
            assert_equal ["good_file.rb:1", "bad_file.rb:2"], parsed["exception"]["stack_trace"]
          end

          it "serializes a nested cause exception message" do
            begin
              begin
                raise bad
              rescue StandardError
                raise "the effect"
              end
            rescue Exception => e
              log.exception = e
            end

            assert_equal "Bad: ", parsed["exception"]["cause"]["message"]
          end

          it "serializes everything at once without raising" do
            log.message    = bad
            log.tags       = [bad]
            log.named_tags = {"key\xE2".b => bad}
            log.payload    = {"outer\xE2".b => {inner: bad}}

            assert JSON.parse(formatter.call(log, appender))
          end

          it "does not mangle valid multibyte UTF-8 in the same document" do
            log.message = "€ café"
            log.payload = {"naïve" => "Bad: \xE2".b}

            assert_equal "€ café", parsed["message"]
            assert_equal({"naïve" => "Bad: "}, parsed["payload"])
          end
        end
      end
    end
  end
end
