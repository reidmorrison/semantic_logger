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

            assert_empty logger.events
          end

          it "Module" do
            logger.filter = ComplexFilter
            logger.send(level, "Exclude this log message", @hash) { "Calculations" }

            assert_empty logger.events
          end

          it "RegExp" do
            logger.filter = ->(log) { (/\AExclude/ =~ log.message).nil? }
            logger.send(level, "Exclude this log message", @hash) { "Calculations" }

            assert_empty logger.events
          end
        end
      end
    end

    describe "when level is too high" do
      it "does not log" do
        logger.level = :error
        logger.info("Exclude this log message")

        assert_empty logger.events
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

    describe "#with_level" do
      it "temporarily changes logging level during the execution of the given block" do
        logger.level = :error

        assert_equal :error, logger.level

        logger.debug("not logged")

        logger.with_level(:debug) do
          assert_equal :debug, logger.level

          logger.debug("logged")
        end

        assert_equal :error, logger.level

        events = logger.events

        assert_equal 1, events.size

        event = events.first

        assert_equal "logged", event.message
        assert_equal :debug, event.level
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
          assert_equal({level1: 1}, SemanticLogger.named_tags)
          assert_equal({level1: 1}, logger.named_tags)
          logger.tagged(level2: 2, more: "data") do
            assert_equal({level1: 1, level2: 2, more: "data"}, SemanticLogger.named_tags)
            assert_equal({level1: 1, level2: 2, more: "data"}, logger.named_tags)
            logger.tagged(level3: 3) do
              assert_equal({level1: 1, level2: 2, more: "data", level3: 3}, SemanticLogger.named_tags)
              assert_equal({level1: 1, level2: 2, more: "data", level3: 3}, logger.named_tags)
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
          assert_same logger, yielded_logger
        end
      end
    end

    describe "#tagged without a block (child logger)" do
      it "returns a new logger instance, not self" do
        child = logger.tagged(cart_id: 5)

        refute_same logger, child
        assert_kind_of logger.class, child
      end

      it "adds named instance tags to every entry from the child" do
        child = logger.tagged(cart_id: 5)
        child.info("hello")

        assert log = child.events.last
        assert_equal({cart_id: 5}, log.named_tags)
      end

      it "adds positional instance tags to every entry from the child" do
        child = logger.tagged("service-a")
        child.info("hello")

        assert log = child.events.last
        assert_equal ["service-a"], log.tags
      end

      it "supports mixing positional and named tags" do
        child = logger.tagged("service-a", cart_id: 5)
        child.info("hello")

        assert log = child.events.last
        assert_equal ["service-a"], log.tags
        assert_equal({cart_id: 5}, log.named_tags)
      end

      it "does not add instance tags to the parent logger" do
        logger.tagged(cart_id: 5)
        logger.info("hello")

        assert log = logger.events.last
        assert_empty log.named_tags
        assert_empty logger.instance_named_tags
      end

      it "does not add instance tags to other loggers within a thread block" do
        another = SemanticLogger::Test::CaptureLogEvents.new
        child   = logger.tagged(cart_id: 5)

        SemanticLogger.tagged("request-1") do
          child.info("from child")
          another.info("from another")
        end

        assert_equal ["request-1"], child.events.last.tags
        assert_equal({cart_id: 5}, child.events.last.named_tags)
        assert_equal ["request-1"], another.events.last.tags
        assert_empty another.events.last.named_tags
      end

      it "layers thread context with instance tags, instance named tags winning on conflict" do
        child = logger.tagged("instance-pos", scope: "instance")

        SemanticLogger.named_tagged(scope: "thread", request_id: "123") do
          SemanticLogger.tagged("thread-pos") do
            child.info("hello")
          end
        end

        assert log = child.events.last
        assert_equal %w[thread-pos instance-pos], log.tags
        assert_equal({scope: "instance", request_id: "123"}, log.named_tags)
      end

      it "merges tags cumulatively for nested child loggers" do
        child      = logger.tagged("a", one: 1)
        grandchild = child.tagged("b", two: 2)
        grandchild.info("hello")

        assert log = grandchild.events.last
        assert_equal %w[a b], log.tags
        assert_equal({one: 1, two: 2}, log.named_tags)
      end

      it "leaves the parent unchanged when building a grandchild" do
        child = logger.tagged("a", one: 1)
        child.tagged("b", two: 2)

        assert_equal ["a"], child.instance_tags
        assert_equal({one: 1}, child.instance_named_tags)
      end

      it "applies instance tags to measure entries" do
        child = logger.tagged(cart_id: 5)
        child.measure_info("timed") { :result }

        assert log = child.events.last
        assert_equal({cart_id: 5}, log.named_tags)
      end

      it "ignores blank positional tags for rails compatibility" do
        child = logger.tagged("", nil, "real")
        child.info("hello")

        assert_equal ["real"], child.events.last.tags
      end
    end
  end
end
