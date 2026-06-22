require_relative "../test_helper"

require "opentelemetry-logs-sdk"
require "semantic_logger/formatters/open_telemetry"

module SemanticLogger
  module Formatters
    class OpenTelemetryTest < Minitest::Test
      describe OpenTelemetry do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:level) do
          :info
        end

        let(:log) do
          log         = SemanticLogger::Log.new("OpenTelemetryTest", level)
          log.time    = log_time
          log.message = "Hello World"
          log
        end

        # The formatter is invoked by the appender as `formatter.call(log, self)`,
        # so the second argument is a Subscriber that responds to host/application/etc.
        let(:appender) do
          InMemoryAppender.new
        end

        let(:formatter) do
          OpenTelemetry.new
        end

        let(:formatted) do
          formatter.call(log, appender)
        end

        describe "level" do
          it "stringifies the level" do
            assert_equal "info", formatted[:level]
          end

          # Regression: severity_number must be resolved from the level symbol,
          # not the integer level_index, otherwise everything is UNSPECIFIED.
          it "maps each level to its Open Telemetry severity number" do
            expected = {
              trace: ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_TRACE,
              debug: ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_DEBUG,
              info:  ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_INFO,
              warn:  ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_WARN,
              error: ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_ERROR,
              fatal: ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_FATAL
            }

            expected.each do |lvl, severity_number|
              entry = SemanticLogger::Log.new("OpenTelemetryTest", lvl)
              result = formatter.call(entry, appender)

              assert_equal severity_number, result[:level_index], "level #{lvl.inspect}"
            end
          end

          it "refutes the unspecified severity number for a known level" do
            refute_equal(
              ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_UNSPECIFIED,
              formatted[:level_index]
            )
          end

          it "falls back to unspecified for an unknown level" do
            assert_equal(
              ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_UNSPECIFIED,
              formatter.send(:severity_number, :bogus)
            )
          end
        end

        describe "payload" do
          it "is omitted when empty" do
            refute formatted.key?(:payload)
          end

          it "passes primitive values through unchanged" do
            log.payload = {count: 5, ratio: 1.5, name: "abc", flag: true}

            assert_equal({"count" => 5, "ratio" => 1.5, "name" => "abc", "flag" => true}, formatted[:payload])
          end

          it "drops nil values" do
            log.payload = {present: 1, missing: nil}

            assert_equal({"present" => 1}, formatted[:payload])
          end

          it "stringifies non-primitive scalar values" do
            log.payload = {sym: :a_symbol}

            assert_equal({"sym" => "a_symbol"}, formatted[:payload])
          end

          it "compacts arrays of scalars" do
            log.payload = {list: [1, nil, "two", :three]}

            assert_equal({"list" => [1, "two", "three"]}, formatted[:payload])
          end

          it "serializes nested hashes to JSON strings" do
            log.payload = {nested: {a: 1, b: :two}}

            assert_equal({"a" => 1, "b" => "two"}.to_json, formatted[:payload]["nested"])
          end
        end

        describe "body" do
          it "includes the message" do
            assert_equal "Hello World", formatted[:message]
          end
        end
      end
    end
  end
end
