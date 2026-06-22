require_relative "../test_helper"

require "opentelemetry-logs-sdk"
require "semantic_logger/appender/open_telemetry"

module Appender
  class OpenTelemetryTest < Minitest::Test
    describe SemanticLogger::Appender::OpenTelemetry do
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

      # The appender registers a global on_log subscriber to capture the Open
      # Telemetry context. Remove it afterwards so it does not pollute other tests.
      after do
        SemanticLogger::Logger.subscribers&.delete(
          SemanticLogger::Appender::OpenTelemetry::CAPTURE_CONTEXT
        )
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

          assert_equal "Hello World", record.body["message"]
          assert_kind_of String, record.body.keys.first
        end

        it "passes the payload through as attributes" do
          record = emit { info("With payload", key1: 1, key2: "a") }.first

          assert_equal 1, record.attributes["key1"]
          assert_equal "a", record.attributes["key2"]
        end

        it "sets the record timestamp from the log time" do
          record = emit { info("timed") }.first

          refute_nil record.timestamp
        end
      end

      describe "flush" do
        it "is a no-op once the provider is closed" do
          appender.close
          assert_nil appender.flush
        end

        it "swallows provider errors" do
          appender.provider.stub(:force_flush, ->(*) { raise "boom" }) do
            appender.flush # does not raise
          end
        end
      end

      describe "close" do
        it "shuts down the provider and clears it" do
          target = appender
          target.close
          assert_nil target.provider
        end

        it "swallows shutdown errors and still clears the provider" do
          target = appender
          target.provider.stub(:shutdown, ->(*) { raise "boom" }) do
            target.close
          end
          assert_nil target.provider
        end
      end
    end
  end
end
