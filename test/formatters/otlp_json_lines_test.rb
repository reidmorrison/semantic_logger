require_relative "../test_helper"
require "tmpdir"

module SemanticLogger
  module Formatters
    class OtlpJsonLinesTest < Minitest::Test
      describe OtlpJsonLines do
        let(:log) do
          log         = SemanticLogger::Log.new("MyApp::Orders", :info)
          log.time    = Time.utc(2026, 11, 25, 8, 32, 5)
          log.message = "Created order"
          log.payload = {order_id: 7}
          log
        end

        let(:appender) { SemanticLogger::Appender::IO.new(StringIO.new, formatter: :otlp_json_lines) }
        let(:formatter) { OtlpJsonLines.new }

        after { appender.close }

        def parse(line) = JSON.parse(line)

        def record(data) = data["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]

        def resource(data)
          data["resourceLogs"][0]["resource"]["attributes"].to_h { |kv| [kv["key"], kv["value"].values.first] }
        end

        def attribute(record, name)
          record["attributes"]&.find { |kv| kv["key"] == name }&.dig("value", "stringValue")
        end

        it "is added with formatter: :otlp_json_lines" do
          assert_instance_of OtlpJsonLines, appender.formatter
        end

        it "writes one LogsData on one line, with the resource, the logger's scope, and the record" do
          line = formatter.call(log, appender)
          data = parse(line)

          refute_includes line, "\n"
          assert_equal "MyApp::Orders", data["resourceLogs"][0]["scopeLogs"][0]["scope"]["name"]
          assert_equal "Created order", record(data)["body"]["stringValue"]
          assert_equal "info", record(data)["severityText"]
          assert_equal ::Process.pid.to_s, resource(data)["process.pid"]
          assert_equal appender.host, resource(data)["host.name"]
        end

        it "writes a LogsData that the OTLP schema can encode" do
          data = JSON.parse(formatter.call(log, appender), symbolize_names: true)

          assert SemanticLogger::Otlp::Protobuf.encode(data, :ExportLogsServiceRequest)
        end

        it "writes the trace the entry was logged in" do
          log.capture(SemanticLogger::Otlp::TraceContext::KEY,
                      ["5b8efff798038103d269b633813fc60c", "eee19b7ec3c1b174", 1])

          assert_equal "5b8efff798038103d269b633813fc60c", record(parse(formatter.call(log, appender)))["traceId"]
          assert_equal SemanticLogger::Otlp::TraceContext::CAPTURES, formatter.source_captures
        end

        it "takes the resource values given over the appender's" do
          formatter = OtlpJsonLines.new(application: "checkout", environment: "production",
                                        resource_attributes: {"service.version" => "1.2"})
          attributes = resource(parse(formatter.call(log, appender)))

          assert_equal "checkout", attributes["service.name"]
          assert_equal "production", attributes["deployment.environment.name"]
          assert_equal "1.2", attributes["service.version"]
        end

        it "uses the global settings without an appender" do
          assert_equal SemanticLogger.host, resource(parse(formatter.call(log, nil)))["host.name"]
        end

        it "passes flatten: to its record formatter" do
          refute OtlpJsonLines.new(flatten: false).record_formatter.flatten
        end

        it "passes the other options to its record formatter" do
          assert OtlpJsonLines.new(log_exception_details: true).record_formatter.log_exception_details
        end

        it "refuses a record_formatter: that is not a Formatters::Otlp" do
          assert_raises(ArgumentError) { OtlpJsonLines.new(record_formatter: :otlp) }
        end

        it "refuses a record_formatter: with options for it" do
          assert_raises(ArgumentError) { OtlpJsonLines.new(record_formatter: Otlp.new, flatten: false) }
        end

        it "takes an application set after the first line, keeping one resource for each appender" do
          formatter.call(log, appender)
          appender.application = "renamed"

          assert_equal "renamed", resource(parse(formatter.call(log, appender)))["service.name"]
          assert_equal "renamed", formatter.instance_variable_get(:@latest_resource)[2].attributes["service.name"]
        end

        it "refuses a max_bytes: that is not a positive Integer" do
          assert_raises(ArgumentError) { OtlpJsonLines.new(max_bytes: 0) }
          assert_raises(ArgumentError) { OtlpJsonLines.new(max_bytes: "1MB") }
        end

        describe "a line over max_bytes:" do
          let(:max_bytes) { 1500 }
          let(:formatter) { OtlpJsonLines.new(max_bytes: max_bytes) }

          before do
            log.exception = RuntimeError.new("boom").tap do |error|
              error.set_backtrace(["app/models/order.rb:1"] * 100)
            end
          end

          it "cuts the stack trace first, and keeps the body" do
            line = formatter.call(log, appender)
            rec  = record(parse(line))

            assert_operator line.bytesize, :<=, max_bytes
            assert attribute(rec, "exception.stacktrace").end_with?(OtlpJsonLines::TRUNCATED)
            assert_equal "Created order", rec["body"]["stringValue"]
            assert_equal "boom", attribute(rec, "exception.message")
          end

          it "then cuts the body, keeping valid UTF-8" do
            log.message = "café ☕ " * 500
            line = formatter.call(log, appender)
            body = record(parse(line))["body"]["stringValue"]

            assert_operator line.bytesize, :<=, max_bytes
            assert body.end_with?(OtlpJsonLines::TRUNCATED)
            assert_predicate body, :valid_encoding?
          end

          it "then drops the largest attributes, and counts them" do
            log.message = "m"
            log.payload = {big: "x" * 3000, small: 1}
            line = formatter.call(log, appender)
            rec  = record(parse(line))

            assert_operator line.bytesize, :<=, max_bytes
            assert_nil attribute(rec, "big")
            assert_operator rec["droppedAttributesCount"], :>=, 1
            assert(rec["attributes"].any? { |kv| kv["key"] == "small" })
          end

          it "fits whatever the cap, once it drops attributes" do
            log.message   = "m"
            log.exception = nil
            log.payload   = {a: "x" * 40, b: "y" * 40, c: "z" * 40}
            full          = OtlpJsonLines.new.call(log, appender).bytesize
            minimum       = OtlpJsonLines.new(max_bytes: 1).call(log, appender).bytesize

            (minimum..full).each do |cap|
              line = OtlpJsonLines.new(max_bytes: cap).call(log, appender)

              assert_operator line.bytesize, :<=, cap, "max_bytes: #{cap}"
            end
          end

          it "is left as it is when it cannot be cut further" do
            formatter = OtlpJsonLines.new(max_bytes: 10)

            assert_operator formatter.call(log, appender).bytesize, :>, 10
          end
        end

        describe "with the file appender" do
          it "writes one line for each entry" do
            Dir.mktmpdir do |dir|
              file_name = File.join(dir, "otlp.jsonl")
              file      = SemanticLogger::Appender::File.new(file_name, formatter: :otlp_json_lines)
              file.log(log)
              file.log(log)
              file.close
              lines = File.readlines(file_name)

              assert_equal 2, lines.size
              assert(lines.all? { |line| record(parse(line))["body"]["stringValue"] == "Created order" })
            end
          end
        end
      end
    end
  end
end
