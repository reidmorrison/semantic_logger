require_relative "test_helper"

# Unit Test for SemanticLogger::Logger
class LoggerTest < Minitest::Test
  describe SemanticLogger::Logger do
    let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }

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
        describe "#filter" do
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
