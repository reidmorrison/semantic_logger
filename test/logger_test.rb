require_relative "test_helper"

# Unit Test for SemanticLogger::Logger
class LoggerTest < Minitest::Test
  describe SemanticLogger::Logger do
    let(:log_filter) { nil }
    let(:logger) do
      l = SemanticLogger::Test::CaptureLogEvents.new
      l.filter = log_filter
      l
    end
    let(:payload) { { session_id: "HSSKLEU@JDK767", tracking_number: 12_345, message: "Message from payload" } }
    let(:dimensions) { { action: "hit", user: "jbloggs", state: "FL" } }

    # Complex filters
    module ComplexFilter
      def self.call(log)
        (/\AExclude/ =~ log.message).nil?
      end
    end

    # Ensure that any log level can be logged
    # SemanticLogger::LEVELS.each do |level|
    [:debug].each do |level|
      describe "##{level}" do
        describe "positional parameter" do
          it "logs message" do
            logger.send(level, "hello world")

            assert log = logger.events.first
            assert_equal "hello world", log.message
          end

          it "adds message from block" do
            logger.send(level, "hello world") { "Calculations" }

            assert log = logger.events.first
            assert_equal "hello world -- Calculations", log.message
          end

          it "logs message and payload" do
            logger.send(level, "hello world", payload)

            assert log = logger.events.first
            assert_equal "hello world", log.message
            assert_equal payload, log.payload
          end

          it "logs simple metric" do
            metric_name = "/my/own/metric"
            logger.send(level, "hello world", metric: metric_name)

            assert log = logger.events.first
            assert_equal "hello world", log.message
            assert_equal metric_name, log.metric
            assert_nil log.payload
            assert_nil log.duration
          end

          it "logs duration" do
            logger.send(level, "hello world", duration: 20)

            assert log = logger.events.first
            assert_equal "hello world", log.message
            assert_equal 20, log.duration
            assert_nil log.payload
            assert_nil log.metric
          end

          it "logs with backtrace" do
            SemanticLogger.stub(:backtrace_level_index, 0) do
              logger.send(level, "hello world", payload) { "Calculations" }

              assert log = logger.events.first
              assert_equal "hello world -- Calculations", log.message
              assert_equal payload, log.payload
              assert log.backtrace
              assert log.backtrace.size.positive?, log.backtrace
            end
          end

          it "logs with backtrace and exception" do
            SemanticLogger.stub(:backtrace_level_index, 0) do
              exc = RuntimeError.new("Test")
              logger.send(level, "hello world", exc)

              assert log = logger.events.first
              assert_equal "hello world", log.message
              assert log.backtrace
              assert log.backtrace.size.positive?, log.backtrace

              assert log.exception
              refute log.exception.backtrace
              assert_equal "RuntimeError", log.exception.class.name
            end
          end
        end

        describe "keyword arguments" do
          it "logs message" do
            logger.send(level, message: "hello world")

            assert log = logger.events.first
            assert_equal "hello world", log.message
          end

          it "logs payload and message" do
            logger.send(level, message: "hello world", payload: payload)

            assert log = logger.events.first
            assert_equal "hello world", log.message
            assert_equal payload, log.payload
          end

          it "logs payload and message without payload arg" do
            logger.send(level, "hello world", **payload)

            assert log = logger.events.first
            assert_equal "hello world", log.message
            assert_equal payload, log.payload
          end

          it "logs message without modifying the supplied hash" do
            details = {message: "hello world"}
            logger.send(level, details)

            assert log = logger.events.first
            assert_equal "hello world", log.message
            assert_equal "hello world", details[:message]
          end

          it "logs payload and message from block" do
            logger.send(level) { { message: "hello world", payload: payload } }

            assert log = logger.events.first
            assert_equal "hello world", log.message
            assert_equal payload, log.payload
          end

          it "logs payload from block" do
            logger.send(level) { { "test_key1" => "hello world", "test_key2" => payload } }

            assert log = logger.events.first
            assert_equal log.payload, "test_key1" => "hello world", "test_key2" => payload
          end

          it "logs payload only" do
            logger.send(level, payload: payload)

            assert log = logger.events.first
            assert_equal payload, log.payload
          end

          it "logs duration" do
            logger.send(level, duration: 123.44, message: "hello world", payload: payload)

            assert log = logger.events.first
            assert_equal "hello world", log.message
            assert_equal payload, log.payload
            assert_equal 123.44, log.duration
          end

          it "does not log when below min_duration" do
            logger.send(
              level,
              min_duration: 200,
              duration:     123.45,
              message:      "hello world",
              payload:      { tracking_number: "123456", even: 2, more: "data" }
            )

            assert logger.events.empty?
          end

          it "logs metric" do
            metric_name = "/my/custom/metric"
            logger.send(level, metric: metric_name, duration: 123.44, message: "hello world", payload: payload)

            assert log = logger.events.first
            assert_equal "hello world", log.message
            assert_equal payload, log.payload
            assert_equal 123.44, log.duration
            assert_equal metric_name, log.metric
          end

          describe "metrics appender" do
            it "logs metric only events" do
              metric_name = "/my/custom/metric"
              logger.send(level, metric: metric_name, dimensions: dimensions)

              assert log = logger.events.first
              assert_equal metric_name, log.metric
              assert_equal dimensions, log.dimensions
            end
          end

          it "for compatibility handles random payload logged as keyword arguments" do
            logger.send(level, payload)

            assert log = logger.events.first
            assert_equal "Message from payload", log.message
            refute log.exception
            refute log.metric
            payload_without_message = payload.dup
            payload_without_message.delete(:message)
            assert_equal payload_without_message, log.payload
          end
        end

        describe "#filter" do
          describe "at the appender level" do
            it "Proc" do
              logger.filter = ->(log) { (/\AExclude/ =~ log.message).nil? }
              logger.send(level, "Exclude this log message", @hash) { "Calculations" }

              assert logger.events.empty?
            end

            it "Module" do
              logger.filter = ComplexFilter
              logger.send(level, "Exclude this log message", @hash) { "Calculations" }

              assert logger.events.empty?
            end

            it "RegExp" do
              logger.filter = ->(log) { (/\AExclude/ =~ log.message).nil? }
              logger.send(level, "Exclude this log message", @hash) { "Calculations" }

              assert logger.events.empty?
            end
          end

          describe "at the logger level" do
            it "Proc" do
              logger.filter = ->(log) { (/\AExclude/ =~ log.message).nil? }
              logger.send(level, "Exclude this log message", @hash) { "Calculations" }

              assert logger.events.empty?
            end

            it "Module" do
              logger.filter = ComplexFilter
              logger.send(level, "Exclude this log message", @hash) { "Calculations" }

              assert logger.events.empty?
            end

            it "RegExp" do
              logger.filter = ->(log) { (/\AExclude/ =~ log.message).nil? }
              logger.send(level, "Exclude this log message", @hash) { "Calculations" }

              assert logger.events.empty?
            end
          end

          describe "on the logger initializer" do
            describe "Proc" do
              let(:log_filter) { ->(log) { (/\AExclude/ =~ log.message).nil? } }

              it "filters" do
                logger.send(level, "Exclude this log message", @hash) { "Calculations" }
                assert logger.events.empty?
              end
            end

            describe "Module" do
              let(:log_filter) { ComplexFilter }

              it "filters" do
                logger.send(level, "Exclude this log message", @hash) { "Calculations" }
                assert logger.events.empty?
              end
            end

            describe "RegExp" do
              let(:log_filter) { /\ALogger/ }

              it "filters" do
                logger.send(level, "Exclude this log message", @hash) { "Calculations" }
                assert logger.events.empty?
              end
            end
          end
        end
      end
    end

    describe "when level is too high" do
      it "does not log" do
        logger.level = :error
        logger.info("Exclude this log message")

        assert logger.events.empty?
      end
    end

    describe "Compatibility" do
      # Ensure that any log level can be logged
      Logger::Severity.constants.each do |level|
        it "log Ruby logger #{level} info" do
          logger.level = Logger::Severity.const_get(level)
          if level.to_s == "UNKNOWN"
            assert_equal Logger::Severity.const_get("ERROR") + 1, logger.send(:level_index)
          else
            assert_equal Logger::Severity.const_get(level) + 1, logger.send(:level_index)
          end
        end
      end
    end

    describe "#level?" do
      it "return true for debug? with :trace level" do
        logger.level = :trace
        assert_equal :trace, logger.level
        assert_equal true, logger.debug?
        assert_equal true, logger.trace?
      end

      it "return false for debug? with instance :debug level" do
        logger.level = :debug
        assert_equal :debug, logger.level, logger.inspect
        assert_equal true, logger.debug?, logger.inspect
        assert_equal false, logger.trace?, logger.inspect
      end

      it "return true for debug? with instance :info level" do
        logger.level = :info
        assert_equal :info, logger.level, logger.inspect
        assert_equal false, logger.debug?, logger.inspect
        assert_equal false, logger.trace?, logger.inspect
      end
    end

    describe ".tagged" do
      it "add tags to log entries" do
        logger.tagged("12345", "DJHSFK") do
          logger.info("hello world")

          assert log = logger.events.first
          assert_equal "hello world", log.message
          assert_equal %w[12345 DJHSFK], log.tags
        end
      end

      it "add embedded tags to log entries" do
        logger.tagged("First Level", "tags") do
          logger.tagged("Second Level") do
            assert_equal ["First Level", "tags", "Second Level"], logger.tags
            logger.info("hello world")

            assert log = logger.events.first
            assert_equal "hello world", log.message
            assert_equal ["First Level", "tags", "Second Level"], log.tags
          end
          assert_equal ["First Level", "tags"], logger.tags
        end
      end

      it "also supports named tagging" do
        logger.tagged(level1: 1) do
          assert_equal({ level1: 1 }, SemanticLogger.named_tags)
          assert_equal({ level1: 1 }, logger.named_tags)
          logger.tagged(level2: 2, more: "data") do
            assert_equal({ level1: 1, level2: 2, more: "data" }, SemanticLogger.named_tags)
            assert_equal({ level1: 1, level2: 2, more: "data" }, logger.named_tags)
            logger.tagged(level3: 3) do
              assert_equal({ level1: 1, level2: 2, more: "data", level3: 3 }, SemanticLogger.named_tags)
              assert_equal({ level1: 1, level2: 2, more: "data", level3: 3 }, logger.named_tags)
            end
          end
        end
      end

      it "is compatible with rails logging that uses arrays and nils" do
        logger.tagged("", %w[12345 DJHSFK], nil) do
          logger.info("hello world")

          assert log = logger.events.first
          assert_equal "hello world", log.message
          assert_equal %w[12345 DJHSFK], log.tags
        end
      end

      it "properly handles logs as an array with a single argument" do
        logger.tagged(%w[first second]) do
          logger.info("hello world")

          assert log = logger.events.first
          assert_equal "hello world", log.message
          assert_equal %w[first second], log.tags
        end
      end

      it "yields self to be compatible with rails tagged logger" do
        logger.tagged("12345", "DJHSFK") do |yielded_logger|
          assert_equal logger.object_id, yielded_logger.object_id
        end
      end
    end
  end
end
