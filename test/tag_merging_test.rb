require_relative "test_helper"

# Tests for tag merging behavior as documented in TAG_MERGING.md
class TagMergingTest < Minitest::Test
  describe "Tag Merging" do
    let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }

    describe "1. Root Logger Cases" do
      describe "1.1 No context" do
        it "logs with empty tags" do
          logger.info("Hello")

          log = logger.events.first

          assert_equal [], log.tags
          assert_equal({}, log.named_tags)
          assert_equal [], log.instance_tags
          assert_equal({}, log.instance_named_tags)
        end
      end

      describe "1.2 With thread tags" do
        it "logs with thread tags from tagged block" do
          logger.tagged("request-123", user: "alice") do
            logger.info("Hello")
          end

          log = logger.events.first

          assert_equal ["request-123"], log.tags
          assert_equal({user: "alice"}, log.named_tags)
          assert_equal [], log.instance_tags
          assert_equal({}, log.instance_named_tags)
        end
      end
    end

    describe "2. Child Logger Cases (No Thread Context)" do
      describe "2.1 With instance tags" do
        it "logs with instance tags" do
          child = logger.tagged("service-a", version: "2.0")

          child.info("Hello")

          log = child.events.first

          assert_equal [], log.tags
          assert_equal({}, log.named_tags)
          assert_equal ["service-a"], log.instance_tags
          assert_equal({version: "2.0"}, log.instance_named_tags)
        end
      end
    end

    describe "3. Child Logger with Thread Context (Independent)" do
      describe "3.1 Instance tags + thread tags (via root)" do
        it "combines thread tags with instance tags" do
          child = logger.tagged("instance-pos", service: "api")

          logger.tagged("thread-pos", request_id: "123") do
            child.info("Hello")
          end

          log = child.events.first

          assert_equal ["thread-pos"], log.tags
          assert_equal({request_id: "123"}, log.named_tags)
          assert_equal ["instance-pos"], log.instance_tags
          assert_equal({service: "api"}, log.instance_named_tags)
        end

      end
    end

    describe "4. Child Logger Inside Own Tagged Block" do
      describe "4.1 Instance tags + own block tags" do
        it "duplicates instance tags in thread tags when child calls tagged with block" do
          child = logger.tagged("instance-pos", service: "api")

          child.tagged("block-pos", request_id: "123") do
            child.info("Hello")
          end

          log = child.events.first

          assert_equal ["instance-pos", "block-pos"], log.tags
          assert_equal({service: "api", request_id: "123"}, log.named_tags)
          assert_equal ["instance-pos"], log.instance_tags
          assert_equal({service: "api"}, log.instance_named_tags)
        end

      end
    end

    describe "5. Nested Child Loggers" do
      describe "5.1 Child of child logger" do
        it "accumulates instance tags through child chain" do
          child1 = logger.tagged("level-1")
          child2 = child1.tagged("level-2")

          child2.info("Hello")

          log = child2.events.first

          assert_equal [], log.tags
          assert_equal({}, log.named_tags)
          assert_equal ["level-1", "level-2"], log.instance_tags
          assert_equal({}, log.instance_named_tags)
        end

      end

      describe "5.2 Child logger inside another child's tagged block" do
        it "combines thread tags from one child with instance tags from another" do
          child1 = logger.tagged("child1-tag", service: "api")
          child2 = logger.tagged("child2-tag", component: "worker")

          child1.tagged("block-tag", request_id: "123") do
            child2.info("Hello")
          end

          log = child2.events.first

          assert_equal ["child1-tag", "block-tag"], log.tags
          assert_equal({service: "api", request_id: "123"}, log.named_tags)
          assert_equal ["child2-tag"], log.instance_tags
          assert_equal({component: "worker"}, log.instance_named_tags)
        end

      end
    end

    describe "6. Edge Cases" do
      describe "6.1 Named tag key conflicts" do
        it "stores conflicting named tags separately in log fields" do
          child = logger.tagged(user: "instance-user")

          child.tagged(user: "block-user") do
            child.info("Hello")
          end

          log = child.events.first

          assert_equal({user: "block-user"}, log.named_tags)
          assert_equal({user: "instance-user"}, log.instance_named_tags)
        end

      end
    end
  end
end
