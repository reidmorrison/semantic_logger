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
      end
    end
  end
end
