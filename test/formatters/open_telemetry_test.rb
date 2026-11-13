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

        let(:attributes) do
          formatted[:attributes]
        end

        let(:backtrace) do
          [
            "test/formatters/open_telemetry_test.rb:99:in `block (2 levels) in <class:OpenTelemetryTest>'",
            "lib/minitest/spec.rb:247:in `instance_eval'"
          ]
        end

        it "returns only the keyword arguments of Logger#on_emit" do
          assert_equal %i[severity_text severity_number timestamp body attributes], formatted.keys
        end

        describe "severity" do
          it "stringifies the level" do
            assert_equal "info", formatted[:severity_text]
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

              assert_equal severity_number, result[:severity_number], "level #{lvl.inspect}"
            end
          end

          it "falls back to unspecified for an unknown level" do
            assert_equal(
              ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_UNSPECIFIED,
              formatter.send(:severity_number, :bogus)
            )
          end
        end

        describe "timestamp" do
          it "is the time of the entry" do
            assert_equal log_time, formatted[:timestamp]
          end
        end

        describe "body" do
          it "is the message" do
            assert_equal "Hello World", formatted[:body]
          end

          it "strips colorizing from the message" do
            log.message = "\e[1mHello\e[0m World"

            assert_equal "Hello World", formatted[:body]
          end

          it "drops invalid UTF-8 bytes from the message" do
            log.message = "Bad: \xFF".dup.force_encoding(Encoding::UTF_8)

            assert_equal "Bad:", formatted[:body]
          end

          it "is nil when the entry has no message" do
            log.message = nil

            assert_nil formatted[:body]
          end
        end

        describe "attributes" do
          it "describes the entry" do
            log.thread_name = "worker"

            expected = {
              "semantic_logger.name" => "OpenTelemetryTest",
              "thread.name"          => "worker",
              "process.pid"          => $$
            }

            assert_equal expected, attributes
          end

          it "does not include the host, application, or environment" do
            refute(attributes.keys.any? { |key| key =~ /host|application|environment/ })
          end

          it "includes the file and line from the backtrace" do
            log.backtrace = backtrace

            assert_equal "test/formatters/open_telemetry_test.rb", attributes["code.file.path"]
            assert_equal 99, attributes["code.line.number"]
          end

          it "includes the tags" do
            log.tags = %w[first second]

            assert_equal %w[first second], attributes["semantic_logger.tags"]
          end

          it "includes the duration and metric" do
            log.duration      = 12.5
            log.metric        = "user/created"
            log.metric_amount = 3

            assert_in_delta 12.5, attributes["semantic_logger.duration_ms"]
            assert_equal "user/created", attributes["semantic_logger.metric"]
            assert_equal 3, attributes["semantic_logger.metric_amount"]
          end

          describe "named tags" do
            it "are attributes of their own" do
              log.named_tags = {request_id: "abc", "user" => "jack"}

              assert_equal "abc", attributes["request_id"]
              assert_equal "jack", attributes["user"]
            end

            # Regression: named tags were in the record body without being coerced, so the OTLP
            # exporter sent a Symbol or Time value as an empty value.
            it "are coerced to attribute values" do
              log.named_tags = {role: :admin, since: Time.utc(2026, 1, 1), ids: [1, :two]}

              assert_equal "admin", attributes["role"]
              assert_equal Time.utc(2026, 1, 1).to_s, attributes["since"]
              assert_equal [1, "two"], attributes["ids"]
            end

            it "give way to a payload key of the same name" do
              log.named_tags = {request_id: "abc"}
              log.payload    = {"request_id" => "xyz"}

              assert_equal "xyz", attributes["request_id"]
            end
          end

          describe "payload" do
            it "is omitted when empty" do
              assert_nil attributes["payload"]
            end

            it "passes primitive values through unchanged" do
              log.payload = {count: 5, ratio: 1.5, name: "abc", flag: true}

              assert_equal(
                {"count" => 5, "ratio" => 1.5, "name" => "abc", "flag" => true},
                attributes.slice("count", "ratio", "name", "flag")
              )
            end

            it "keeps a key named like the logger name field of other formatters" do
              log.payload = {name: "Jack"}

              assert_equal "Jack", attributes["name"]
              assert_equal "OpenTelemetryTest", attributes["semantic_logger.name"]
            end

            it "drops nil values" do
              log.payload = {present: 1, missing: nil}

              assert_equal 1, attributes["present"]
              refute attributes.key?("missing")
            end

            it "stringifies non-primitive scalar values" do
              log.payload = {sym: :a_symbol}

              assert_equal "a_symbol", attributes["sym"]
            end

            it "compacts arrays of scalars" do
              log.payload = {list: [1, nil, "two", :three]}

              assert_equal [1, "two", "three"], attributes["list"]
            end

            it "serializes nested hashes to JSON strings" do
              log.payload = {nested: {a: 1, b: :two}}

              assert_equal({"a" => 1, "b" => "two"}.to_json, attributes["nested"])
            end

            it "submits a payload that is not a Hash as a single attribute" do
              log.payload = "just a string"

              assert_equal "just a string", attributes["payload"]
            end

            it "writes a Struct or Set as JSON of its members, not its #inspect" do
              client      = Class.new { def initialize = (@password = "hunter2") }.new
              log.payload = {client: Struct.new(:name, :api).new("billing", client), set: Set[client], list: [Set[1]]}

              refute_includes attributes.to_s, "hunter2"
              assert_equal "billing", JSON.parse(attributes["client"])["name"]
              assert_equal ["[1]"], attributes["list"]
            end

            it "drops invalid UTF-8 bytes from keys and values" do
              log.payload = {"key\xFF".dup.force_encoding(Encoding::UTF_8) => "value\xFF".dup.force_encoding(Encoding::UTF_8)}

              assert_equal "value", attributes["key"]
            end
          end

          describe "a named tag or payload key named like one of the entry's own attributes" do
            it "is prefixed with its source" do
              log.named_tags = {"thread.name" => "forged"}
              log.payload    = {"semantic_logger.name" => "forged", "exception.type" => "Forged"}

              assert_equal "forged", attributes["named_tags.thread.name"]
              assert_equal "forged", attributes["payload.semantic_logger.name"]
              assert_equal "Forged", attributes["payload.exception.type"]
              assert_equal "OpenTelemetryTest", attributes["semantic_logger.name"]
              refute attributes.key?("exception.type")
            end

            it "is prefixed when it is a Symbol" do
              log.payload = {"process.pid": 1}

              assert_equal 1, attributes["payload.process.pid"]
              assert_equal $$, attributes["process.pid"]
            end
          end

          describe "exception" do
            let(:exception) do
              begin
                raise ArgumentError, "inner"
              rescue ArgumentError
                raise "Oh no"
              end
            rescue RuntimeError => e
              e
            end

            before do
              log.exception = exception
            end

            it "uses the semantic convention attributes" do
              assert_equal "RuntimeError", attributes["exception.type"]
              assert_equal "Oh no", attributes["exception.message"]
            end

            it "includes the backtrace of the exception and of each exception that caused it" do
              stacktrace = attributes["exception.stacktrace"]

              assert_equal exception.backtrace.first, stacktrace.lines.first.chomp
              assert_includes stacktrace, "Cause: ArgumentError: inner"
            end

            it "leaves the message as the body" do
              assert_equal "Hello World", formatted[:body]
            end

            it "omits the stacktrace of an exception that was never raised" do
              log.exception = RuntimeError.new("not raised")

              assert_equal "not raised", attributes["exception.message"]
              refute attributes.key?("exception.stacktrace")
            end
          end
        end
      end
    end
  end
end
