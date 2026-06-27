require_relative "test_helper"

module SemanticLogger
  class BaseTest < Minitest::Test
    # Concrete subclass that captures emitted Log objects directly,
    # bypassing the appender pipeline so that Base's own logic can be tested in isolation.
    class CaptureLogger < SemanticLogger::Base
      attr_reader :logs

      def initialize(name = "BaseTest", level = nil, filter = nil)
        @logs = []
        super
      end

      def log(log)
        @logs << log
        true
      end
    end

    describe SemanticLogger::Base do
      let(:logger) do
        CaptureLogger.new
      end

      let(:last_log) do
        logger.logs.last
      end

      before do
        SemanticLogger.default_level = :trace
      end

      describe "#level=" do
        it "accepts a symbol" do
          logger.level = :warn

          assert_equal :warn, logger.level
        end

        it "accepts a string" do
          logger.level = "warn"

          assert_equal :warn, logger.level
        end

        it "accepts a ::Logger integer level" do
          logger.level = ::Logger::WARN

          assert_equal :warn, logger.level
        end

        it "falls back to the global default when set to nil" do
          logger.level = :warn
          logger.level = nil

          assert_equal SemanticLogger.default_level, logger.level
        end
      end

      describe "#with_level" do
        it "temporarily changes the level" do
          logger.level = :info

          logger.with_level(:debug) do
            assert_equal :debug, logger.level
          end
          assert_equal :info, logger.level
        end

        it "restores the level even when the block raises" do
          logger.level = :info
          assert_raises(RuntimeError) do
            logger.with_level(:debug) { raise "boom" }
          end
          assert_equal :info, logger.level
        end
      end

      describe "level query methods" do
        it "returns true when the level is enabled" do
          logger.level = :debug

          assert_predicate logger, :debug?
          assert_predicate logger, :warn?
        end

        it "returns false when the level is disabled" do
          logger.level = :warn

          refute_predicate logger, :debug?
          refute_predicate logger, :info?
        end
      end

      describe "log level methods" do
        it "returns true and logs when enabled" do
          logger.level = :trace

          assert_equal true, logger.info("Hello")
          assert_equal "Hello", last_log.message
          assert_equal :info, last_log.level
        end

        it "returns false and does not log when disabled" do
          logger.level = :error

          assert_equal false, logger.info("Hello")
          assert_empty logger.logs
        end
      end

      describe "argument parsing" do
        it "treats a leading exception as the exception" do
          exception = RuntimeError.new("boom")
          logger.error(exception)

          assert_equal exception, last_log.exception
          assert_nil last_log.message
        end

        it "treats a second-argument exception as the exception" do
          exception = RuntimeError.new("boom")
          logger.error("Failed", exception)

          assert_equal exception, last_log.exception
          assert_equal "Failed", last_log.message
        end

        it "appends a non-hash payload to the message" do
          logger.info("Count", 42)

          assert_equal "Count -- 42", last_log.message
          assert_nil last_log.payload
        end

        it "splits a hash message into message and payload" do
          logger.info(message: "Hello", user: "joe")

          assert_equal "Hello", last_log.message
          assert_equal({user: "joe"}, last_log.payload)
        end

        it "accepts a message with a hash payload" do
          logger.info("Hello", user: "joe")

          assert_equal "Hello", last_log.message
          assert_equal({user: "joe"}, last_log.payload)
        end
      end

      describe "block forms" do
        it "uses a string block result as the message" do
          logger.info { "From block" }

          assert_equal "From block", last_log.message
        end

        it "appends a string block result to the message" do
          logger.info("Base") { "more" }

          assert_equal "Base -- more", last_log.message
        end

        it "merges a hash block result" do
          logger.info("Hello") { {user: "joe"} }

          assert_equal "Hello", last_log.message
          assert_equal({user: "joe"}, last_log.payload)
        end

        it "supports a zero-arity lambda" do
          logger.info(&-> { "From lambda" })

          assert_equal "From lambda", last_log.message
        end

        it "passes the log to a block that accepts an argument" do
          yielded = nil
          logger.info("Hello") do |log|
            yielded = log
            nil
          end

          assert_instance_of SemanticLogger::Log, yielded
          assert_equal "Hello", yielded.message
        end
      end

      describe "#measure_<level>" do
        it "logs the measured duration and returns the block result" do
          result = logger.measure_info("Work") { 123 }

          assert_equal 123, result
          assert_equal "Work", last_log.message
          refute_nil last_log.duration
        end

        it "does not measure when the level is disabled but still runs the block" do
          logger.level = :error
          result = logger.measure_info("Work") { 123 }

          assert_equal 123, result
          assert_empty logger.logs
        end

        it "logs and re-raises an exception raised in the block" do
          assert_raises(RuntimeError) do
            logger.measure_info("Work") { raise "boom" }
          end
          assert_equal "Work -- Exception: RuntimeError: boom", last_log.message
        end

        it "suppresses logging when the duration is below min_duration" do
          logger.measure_info("Work", min_duration: 1_000_000) { 1 }

          assert_empty logger.logs
        end
      end

      describe "#measure" do
        it "supplies the level dynamically" do
          logger.measure(:warn, "Dynamic") { 1 }

          assert_equal :warn, last_log.level
          assert_equal "Dynamic", last_log.message
        end
      end

      describe "#backtrace" do
        it "logs a thread backtrace" do
          logger.backtrace(level: :error, message: "Trace:")

          assert_equal :error, last_log.level
          assert_match(/\ATrace:/, last_log.message)
        end
      end

      describe "#should_log?" do
        it "is false when the filter rejects the log" do
          filtered = CaptureLogger.new("Other", :trace, /\AInclude/)
          log = SemanticLogger::Log.new("Excluded", :info)

          refute filtered.should_log?(log)
        end

        it "is true when the filter matches and level is met" do
          filtered = CaptureLogger.new("Other", :trace, /\AInclude/)
          log = SemanticLogger::Log.new("IncludeMe", :info)

          assert filtered.should_log?(log)
        end

        it "is false when the level is not met" do
          logger.level = :error
          log = SemanticLogger::Log.new("BaseTest", :info)

          refute logger.should_log?(log)
        end
      end

      describe "#initialize filter validation" do
        it "raises for an invalid filter" do
          assert_raises(RuntimeError) do
            CaptureLogger.new("Bad", :trace, "not a filter")
          end
        end

        it "accepts a Proc filter" do
          proc_filter = ->(log) { log.message == "keep" }
          logger = CaptureLogger.new("Proc", :trace, proc_filter)

          assert logger.should_log?(SemanticLogger::Log.new("Proc", :info).tap { |l| l.message = "keep" })
          refute logger.should_log?(SemanticLogger::Log.new("Proc", :info).tap { |l| l.message = "drop" })
        end
      end
    end
  end
end
