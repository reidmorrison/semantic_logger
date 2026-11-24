require_relative "../test_helper"

# Only the OpenTelemetry API, to put a span in the context, as an application that traces does.
require "opentelemetry"

module SemanticLogger
  module Formatters
    class OtlpTest < Minitest::Test
      TRACE_ID = "5b8efff798038103d269b633813fc60c".freeze
      SPAN_ID  = "eee19b7ec3c1b174".freeze

      describe Otlp do
        let(:log_time) { Time.at(1_700_000_000, 123_456_789, :nsec) }
        let(:log) do
          log         = SemanticLogger::Log.new("MyApp::Orders", :warn)
          log.time    = log_time
          log.message = "Charged"
          log
        end
        let(:appender) { InMemoryAppender.new }
        let(:formatter) { Otlp.new }
        let(:record) { formatter.call(log, appender) }

        # Returns [Hash] the attributes of the record, by key.
        def attributes(record = self.record)
          (record[:attributes] || []).to_h { |attribute| [attribute[:key], attribute[:value]] }
        end

        it "writes the time, severity, and body" do
          assert_equal "1700000000123456789", record[:timeUnixNano]
          assert_equal "1700000000123456789", record[:observedTimeUnixNano]
          assert_equal 13, record[:severityNumber]
          assert_equal "warn", record[:severityText]
          assert_equal({stringValue: "Charged"}, record[:body])
        end

        it "has the severity number of each level" do
          numbers = %i[trace debug info warn error fatal].map do |level|
            log.level = level
            formatter.call(log, appender)[:severityNumber]
          end

          assert_equal [1, 5, 9, 13, 17, 21], numbers
        end

        it "has no body without a message" do
          log.message = nil

          refute record.key?(:body)
        end

        it "keeps the structure of a payload, as a kvlistValue and an arrayValue" do
          log.payload = {order: {id: 7, items: [1, "two", nil, true]}, big: 2**70, ratio: 0.5}

          assert_equal(
            {
              kvlistValue: {
                values: [
                  {key: "id", value: {intValue: "7"}},
                  {
                    key:   "items",
                    value: {arrayValue: {values: [{intValue: "1"}, {stringValue: "two"}, {}, {boolValue: true}]}}
                  }
                ]
              }
            },
            attributes["order"]
          )
          assert_equal({stringValue: (2**70).to_s}, attributes["big"])
          assert_equal({doubleValue: 0.5}, attributes["ratio"])
        end

        it "writes a structure nested too deeply as a placeholder, so that the JSON of the request can be written" do
          deep = {}
          inner = deep
          40.times { inner = inner[:a] = {} }
          log.payload = {deep: deep}
          request     = {resourceLogs: [{scopeLogs: [{logRecords: [record]}]}]}
          text        = SemanticLogger::Otlp::Protocol["http/json"].encode(request, :ExportLogsServiceRequest)

          assert_includes text, "#<Hash nested too deeply>"
          assert_equal 20, text.scan("kvlistValue").size
        end

        it "writes a Struct as its members, never through its inspect" do
          log.payload = {point: Struct.new(:x, :y).new(1, 2)}

          members = [{key: "x", value: {intValue: "1"}}, {key: "y", value: {intValue: "2"}}]

          assert_equal({kvlistValue: {values: members}}, attributes["point"])
        end

        it "names the entry's own fields as the OpenTelemetry formatter does" do
          log.duration    = 12.5
          log.thread_name = "worker-1"
          log.tags        = %w[a b]
          log.named_tags  = {user: "jack"}

          assert_equal({doubleValue: 12.5}, attributes["semantic_logger.duration_ms"])
          assert_equal({stringValue: "worker-1"}, attributes["thread.name"])
          assert_equal({arrayValue: {values: [{stringValue: "a"}, {stringValue: "b"}]}},
                       attributes["semantic_logger.tags"])
          assert_equal({stringValue: "jack"}, attributes["user"])
        end

        it "leaves out the logger name and the process id, which the scope and the resource hold" do
          log.thread_name = "worker-1"

          refute attributes.key?("semantic_logger.name")
          refute attributes.key?("process.pid")
        end

        it "writes an exception" do
          log.exception = RuntimeError.new("boom")

          assert_equal({stringValue: "RuntimeError"}, attributes["exception.type"])
          assert_equal({stringValue: "boom"}, attributes["exception.message"])
        end

        it "writes invalid UTF-8 as valid UTF-8" do
          log.message = "caf\xE9".b
          log.payload = {"k\xFF".b => "v\xFF".b}

          assert_predicate record[:body][:stringValue], :valid_encoding?
          assert(attributes.keys.all?(&:valid_encoding?))
          assert(attributes.values.all? { |value| value[:stringValue].valid_encoding? })
        end

        describe "trace" do
          after do
            SemanticLogger::Logger.subscribers&.delete(SemanticLogger::Otlp::TraceContext::CAPTURE)
          end

          # Runs the block in a span with the ids, and the flags.
          def in_span(flags = ::OpenTelemetry::Trace::TraceFlags::SAMPLED, &)
            context = ::OpenTelemetry::Trace::SpanContext.new(
              trace_id:    [TRACE_ID].pack("H*"),
              span_id:     [SPAN_ID].pack("H*"),
              trace_flags: flags
            )
            ::OpenTelemetry::Trace.with_span(::OpenTelemetry::Trace.non_recording_span(context), &)
          end

          it "has the ids and flags of the span that was current when it was logged" do
            in_span { SemanticLogger::Otlp::TraceContext::CAPTURE.call(log) }

            assert_equal TRACE_ID, record[:traceId]
            assert_equal SPAN_ID, record[:spanId]
            assert_equal 1, record[:flags]
          end

          it "has flags of 0 for a span that is not sampled" do
            in_span(::OpenTelemetry::Trace::TraceFlags::DEFAULT) { SemanticLogger::Otlp::TraceContext::CAPTURE.call(log) }

            assert_equal 0, record[:flags]
          end

          it "captures nothing outside a span" do
            SemanticLogger::Otlp::TraceContext::CAPTURE.call(log)

            assert_nil log.captured(SemanticLogger::Otlp::TraceContext::KEY)
            refute record.key?(:traceId)
          end

          it "takes the trace from the trace_id and span_id named tags, which are then not attributes" do
            log.named_tags = {trace_id: TRACE_ID.upcase, "span_id" => SPAN_ID, user: "jack"}

            assert_equal TRACE_ID, record[:traceId]
            assert_equal SPAN_ID, record[:spanId]
            refute record.key?(:flags)
            assert_equal ["user"], attributes.keys.grep(/user|_id/)
          end

          it "takes the trace without the span_id named tag when it is not a span id" do
            log.named_tags = {trace_id: TRACE_ID, span_id: "123"}

            assert_equal TRACE_ID, record[:traceId]
            refute record.key?(:spanId)
            assert_equal({stringValue: "123"}, attributes["span_id"])
          end

          it "keeps named tags that are not valid ids as attributes" do
            ["abc", "0" * 32, "#{TRACE_ID}0", 12_345].each do |trace_id|
              log.named_tags = {trace_id: trace_id, span_id: SPAN_ID}
              record         = formatter.call(log, appender)

              refute record.key?(:traceId), trace_id.inspect
              assert attributes(record).key?("trace_id")
              assert attributes(record).key?("span_id")
            end
          end

          it "prefers the span to the named tags, which are then attributes" do
            log.named_tags = {trace_id: "1" * 32}
            in_span { SemanticLogger::Otlp::TraceContext::CAPTURE.call(log) }

            assert_equal TRACE_ID, record[:traceId]
            assert_equal({stringValue: "1" * 32}, attributes["trace_id"])
          end
        end
      end
    end
  end
end
