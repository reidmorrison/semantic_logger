require_relative "../test_helper"

require "opentelemetry-logs-sdk"
require "semantic_logger/appender/open_telemetry"

module Appender
  class OpenTelemetryTest < Minitest::Test
    describe SemanticLogger::Appender::OpenTelemetry do
      allow_deprecation(/appender: :open_telemetry\) is deprecated/)

      it "is deprecated, naming appender: :otlp" do
        ::OpenTelemetry.logger_provider = provider
        assert_deprecated(/deprecated and will be removed in v7\. Use appender: :otlp/) do
          SemanticLogger::Appender::OpenTelemetry.new
        end
      end

      let(:exporter) do
        ::OpenTelemetry::SDK::Logs::Export::InMemoryLogRecordExporter.new
      end

      let(:provider) do
        provider = ::OpenTelemetry::SDK::Logs::LoggerProvider.new
        processor = ::OpenTelemetry::SDK::Logs::Export::SimpleLogRecordProcessor.new(exporter)
        provider.add_log_record_processor(processor)
        provider
      end

      let(:appender) do
        ::OpenTelemetry.logger_provider = provider
        SemanticLogger::Appender::OpenTelemetry.new
      end

      it "captures the Open Telemetry context of the thread that logs each entry" do
        assert_includes appender.source_captures, SemanticLogger::Appender::OpenTelemetry::CAPTURE_CONTEXT
      end

      # Emit a log through the appender and return the single exported record.
      def emit(&block)
        appender.instance_eval(&block)
        provider.force_flush
        exporter.emitted_log_records
      end

      describe "initialize" do
        it "uses the configured global logger provider" do
          assert_same provider, appender.provider
        end

        it "defaults name and version" do
          assert_equal "SemanticLogger", appender.name
          assert_equal SemanticLogger::VERSION, appender.version
        end

        it "defaults to the Open Telemetry formatter" do
          assert_instance_of SemanticLogger::Formatters::OpenTelemetry, appender.formatter
        end

        it "uses the Open Telemetry formatter when given a nil formatter" do
          ::OpenTelemetry.logger_provider = provider
          given_nil = SemanticLogger::Appender::OpenTelemetry.new(formatter: nil)

          assert_instance_of SemanticLogger::Formatters::OpenTelemetry, given_nil.formatter
        end

        it "restores the Open Telemetry formatter when the formatter is set to nil" do
          appender.formatter = :json
          appender.formatter = nil

          assert_instance_of SemanticLogger::Formatters::OpenTelemetry, appender.formatter
        end
      end

      describe "metric-only entries" do
        let(:metric_only) do
          log        = SemanticLogger::Log.new("Test", :info)
          log.metric = "users/signup"
          log
        end

        it "leaves them out by default" do
          refute appender.should_log?(metric_only)
        end

        it "sends them with metrics: true" do
          ::OpenTelemetry.logger_provider = provider
          with_metrics = SemanticLogger::Appender::OpenTelemetry.new(metrics: true)

          assert with_metrics.should_log?(metric_only)
        end
      end

      describe "log" do
        SemanticLogger::Levels::LEVELS.each do |level|
          it "emits a #{level} record" do
            records = emit { send(level, "#{level} message") }

            assert_equal 1, records.size
            record = records.first

            assert_equal level.to_s, record.severity_text
            refute_equal(
              ::OpenTelemetry::Logs::SeverityNumber::SEVERITY_NUMBER_UNSPECIFIED,
              record.severity_number,
              "level #{level} should map to a specific severity number"
            )
          end
        end

        it "places the message in the record body" do
          record = emit { info("Hello World") }.first

          assert_equal "Hello World", record.body
        end

        it "passes the payload through as attributes" do
          record = emit { info("With payload", key1: 1, key2: "a") }.first

          assert_equal 1, record.attributes["key1"]
          assert_equal "a", record.attributes["key2"]
        end

        it "passes the named tags through as attributes" do
          record = SemanticLogger.named_tagged(request_id: "abc") { emit { info("Tagged") } }.first

          assert_equal "abc", record.attributes["request_id"]
        end

        it "describes the exception with the semantic convention attributes" do
          record = emit do
            raise ArgumentError, "Oh no"
          rescue ArgumentError => e
            error("Failed", e)
          end.first

          assert_equal "Failed", record.body
          assert_equal "ArgumentError", record.attributes["exception.type"]
          assert_equal "Oh no", record.attributes["exception.message"]
          assert_includes record.attributes["exception.stacktrace"], "open_telemetry_test.rb"
        end

        it "correlates the record with the active span" do
          tracer = ::OpenTelemetry::SDK::Trace::TracerProvider.new.tracer("test")
          span   = nil
          record = tracer.in_span("request") do |current|
            span = current
            emit { info("In a span") }
          end.first

          assert_equal span.context.trace_id, record.trace_id
          assert_equal span.context.span_id, record.span_id
        end

        # The appender usually runs on a worker thread, after the span has ended.
        it "correlates the record with the span that was active when the entry was logged" do
          tracer = ::OpenTelemetry::SDK::Trace::TracerProvider.new.tracer("test")
          span   = nil
          log    = SemanticLogger::Log.new("OpenTelemetryTest", :info)
          log.message = "Captured"
          tracer.in_span("request") do |current|
            span = current
            SemanticLogger::Appender::OpenTelemetry::CAPTURE_CONTEXT.call(log)
          end

          appender.log(log)
          provider.force_flush
          record = exporter.emitted_log_records.first

          assert_equal span.context.trace_id, record.trace_id
          assert_equal span.context.span_id, record.span_id
        end

        it "sets the record timestamp from the log time" do
          record = emit { info("timed") }.first

          refute_nil record.timestamp
        end
      end

      describe "async: true" do
        it "emits log records from its own thread" do
          proxy       = SemanticLogger::Appender::Async.new(appender: appender)
          log         = SemanticLogger::Log.new("OpenTelemetryTest", :info)
          log.message = "From the worker"
          proxy.log(log)

          assert proxy.flush, "the worker thread should be running to flush"
          assert_equal ["From the worker"], exporter.emitted_log_records.map(&:body)
        ensure
          proxy&.close
        end
      end

      describe "logger" do
        it "is the internal logger every appender reports its own problems to" do
          assert_kind_of SemanticLogger::Subscriber, appender.logger
          assert_equal "SemanticLogger::Appender::OpenTelemetry", appender.logger.name
        end

        it "can be replaced without changing where log records are emitted" do
          appender.logger = SemanticLogger::Test::CaptureLogEvents.new
          record          = emit { info("Still emitted") }.first

          assert_equal "Still emitted", record.body
        end
      end

      describe "flush" do
        it "is a no-op once the provider is closed" do
          appender.close

          assert_nil appender.flush
        end

        it "swallows provider errors and reports them to its internal logger" do
          internal        = SemanticLogger::Test::CaptureLogEvents.new
          appender.logger = internal
          appender.provider.stub(:force_flush, ->(*) { raise "boom" }) do
            appender.flush # does not raise
          end

          assert_equal ["Flush failed"], internal.events.map(&:message)
          assert_equal "boom", internal.events.first.exception.message
        end
      end

      describe "close" do
        it "shuts down the provider and clears it" do
          target = appender
          target.close

          assert_nil target.provider
        end

        it "swallows shutdown errors, reports them to its internal logger, and still clears the provider" do
          internal      = SemanticLogger::Test::CaptureLogEvents.new
          target        = appender
          target.logger = internal
          target.provider.stub(:shutdown, ->(*) { raise "boom" }) do
            target.close
          end

          assert_nil target.provider
          assert_equal ["Shutdown failed"], internal.events.map(&:message)
          assert_equal "boom", internal.events.first.exception.message
        end
      end
    end
  end
end
