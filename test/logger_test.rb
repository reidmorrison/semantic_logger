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
          assert_equal logger.object_id, yielded_logger.object_id
        end
      end
    end

    describe ".tagged without block" do
      it "creates a child logger with instance named tags merged with parent" do
        parent_tag_data = {parent_tag: "parent_value"}
        child_tag_data = {tag1: "value1", tag2: "value2"}
        parent_logger = logger.tagged(**parent_tag_data)
        child_logger = parent_logger.tagged(**child_tag_data)

        child_logger.info("hello world")

        assert_equal parent_tag_data, parent_logger.instance_named_tags
        assert_equal parent_tag_data.merge(child_tag_data), child_logger.instance_named_tags
      end

      it "outputs log entries with different instance named tags from the parent" do
        parent_tag_data = {parent_tag: "parent_value"}
        child_tag_data = {tag1: "value1", tag2: "value2"}
        parent_logger = logger.tagged(**parent_tag_data)
        child_logger = parent_logger.tagged(**child_tag_data)

        parent_logger.info("hello parent")

        assert log_parent = parent_logger.events.first
        assert_equal "hello parent", log_parent.message
        assert_equal parent_tag_data, log_parent.instance_named_tags

        child_logger.info("hello child")

        assert log_child = child_logger.events.first
        assert_equal "hello child", log_child.message
        assert_equal parent_tag_data.merge(child_tag_data), log_child.instance_named_tags
      end

      it "creates a child logger with instance positional tags" do
        tagged_logger = logger.tagged("tag1", "tag2")

        tagged_logger.info("hello world")

        assert_equal %w[tag1 tag2], tagged_logger.instance_tags
        assert log = tagged_logger.events.first
        assert_equal "hello world", log.message
        assert_equal %w[tag1 tag2], log.instance_tags
      end

      it "creates a child logger with instance positional tags merged with parent" do
        parent_logger = logger.tagged("parent_tag")
        child_logger = parent_logger.tagged("child_tag1", "child_tag2")

        child_logger.info("hello world")

        assert_equal %w[parent_tag], parent_logger.instance_tags
        assert_equal %w[parent_tag child_tag1 child_tag2], child_logger.instance_tags
      end

      it "creates a child logger with both positional and named instance tags" do
        tagged_logger = logger.tagged("tag1", "tag2", user: "alice", request_id: "123")

        tagged_logger.info("hello world")

        assert_equal %w[tag1 tag2], tagged_logger.instance_tags
        assert_equal({user: "alice", request_id: "123"}, tagged_logger.instance_named_tags)
        assert log = tagged_logger.events.first
        assert_equal %w[tag1 tag2], log.instance_tags
        assert_equal({user: "alice", request_id: "123"}, log.instance_named_tags)
      end

      it "prefixes instance tags to thread tags in log entries" do
        tagged_logger = logger.tagged("instance_tag")

        SemanticLogger.tagged("thread_tag") do
          tagged_logger.info("hello world")
        end

        assert log = tagged_logger.events.first
        assert_equal %w[instance_tag], log.instance_tags
        assert_equal %w[thread_tag], log.tags
      end

      it "pushes instance tags to thread when tagged is called with a block" do
        tagged_logger = logger.tagged("instance_tag1", "instance_tag2")

        tagged_logger.tagged("block_tag") do
          tagged_logger.info("hello world")
        end

        assert log = tagged_logger.events.first
        assert_equal "hello world", log.message
        assert_equal %w[instance_tag1 instance_tag2 block_tag], log.tags
      end

      it "pushes instance named tags to thread when tagged is called with a block" do
        tagged_logger = logger.tagged(user: "alice", request_id: "123")

        tagged_logger.tagged do
          tagged_logger.info("hello world")
        end

        assert log = tagged_logger.events.first
        assert_equal "hello world", log.message
        assert_equal({user: "alice", request_id: "123"}, log.named_tags)
      end

      it "merges instance named tags with block named tags" do
        tagged_logger = logger.tagged(user: "alice")

        tagged_logger.tagged(request_id: "123") do
          tagged_logger.info("hello world")
        end

        assert log = tagged_logger.events.first
        assert_equal "hello world", log.message
        assert_equal({user: "alice", request_id: "123"}, log.named_tags)
      end

      it "combines instance tags and named tags with block tags" do
        tagged_logger = logger.tagged("instance_tag", user: "alice")

        tagged_logger.tagged("block_tag", request_id: "123") do
          tagged_logger.info("hello world")
        end

        assert log = tagged_logger.events.first
        assert_equal "hello world", log.message
        assert_equal %w[instance_tag block_tag], log.tags
        assert_equal({user: "alice", request_id: "123"}, log.named_tags)
      end

      it "makes instance tags visible to other loggers via thread variables" do
        child_logger = logger.tagged("child1", n_child1: "val1")

        child_logger.tagged("tagged1", n_tagged1: "tval1") do
          thread_logger = SemanticLogger::Test::CaptureLogEvents.new
          thread_logger.info("whatever")

          log = thread_logger.events.first

          assert_equal %w[child1 tagged1], log.tags
          assert_equal({n_child1: "val1", n_tagged1: "tval1"}, log.named_tags)
        end
      end

      it "combines thread tags with nested child logger instance tags" do
        child_logger = logger.tagged("child1", n_child1: "val1")

        child_logger.tagged("tagged1", n_tagged1: "tval1") do
          thread_logger = SemanticLogger::Test::CaptureLogEvents.new
          cthread_log = thread_logger.tagged("t1", tn1: "tnval1")
          cthread_log.info("whatever")

          log = cthread_log.events.first

          assert_equal %w[child1 tagged1], log.tags
          assert_equal({n_child1: "val1", n_tagged1: "tval1"}, log.named_tags)
          assert_equal %w[t1], log.instance_tags
          assert_equal({tn1: "tnval1"}, log.instance_named_tags)
        end
      end
    end
  end
end
