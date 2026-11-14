require_relative "test_helper"

module SemanticLogger
  class ContextTest < Minitest::Test
    describe SemanticLogger::Context do
      let(:logger) { SemanticLogger::Logger.new("ContextTest") }

      # Copy the current fiber's fiber-local variables into a new thread, the way Rails'
      # ActionController::Live hands a request's state to its streaming thread.
      def thread_with_copied_locals(&block)
        locals = Thread.current.keys.map { |key| [key, Thread.current[key]] }
        Thread.new do
          locals.each { |key, value| Thread.current[key] = value }
          block.call
        end
      end

      describe "a thread that copied the fiber-local variables" do
        it "keeps the tags after the parent leaves its blocks" do
          started  = Queue.new
          continue = Queue.new
          thread   = nil
          SemanticLogger.tagged("request") do
            SemanticLogger.tagged(request_id: 42) do
              SemanticLogger.silence(:warn) do
                thread = thread_with_copied_locals do
                  started << true
                  continue.pop
                  [SemanticLogger.tags, SemanticLogger.named_tags, SemanticLogger.default_level_index]
                end
                started.pop
              end
            end
          end
          continue << true
          tags, named_tags, level_index = thread.value

          assert_equal ["request"], tags
          assert_equal({request_id: 42}, named_tags)
          assert_equal Levels.index(:warn), level_index
        end

        it "keeps the with_level override after the parent leaves its block" do
          started  = Queue.new
          continue = Queue.new
          thread   = nil
          logger.with_level(:error) do
            thread = thread_with_copied_locals do
              started << true
              continue.pop
              logger.level
            end
            started.pop
          end
          continue << true

          assert_equal :error, thread.value
        end

        it "does not change the parent's tags" do
          SemanticLogger.tagged("request") do
            thread_with_copied_locals do
              SemanticLogger.push_tags("child")
              SemanticLogger.named_tagged(child: true) { SemanticLogger.pop_tags(2) }
            end.join

            assert_equal ["request"], SemanticLogger.tags
            assert_empty SemanticLogger.named_tags
          end
        end
      end

      describe "block forms" do
        it "restore the tags when the block exits, even when it pushed tags it did not pop" do
          SemanticLogger.tagged("outer") do
            SemanticLogger.tagged("inner") { SemanticLogger.push_tags("unbalanced") }

            assert_equal ["outer"], SemanticLogger.tags
          end

          assert_empty SemanticLogger.tags
        end

        it "restore the named tags when the block exits, even when it pushed named tags it did not pop" do
          SemanticLogger.tagged(user: "jack") do
            SemanticLogger.tagged(id: 1) { SemanticLogger.push_named_tags(extra: true) }

            assert_equal({user: "jack"}, SemanticLogger.named_tags)
          end

          assert_empty SemanticLogger.named_tags
        end

        it "restore the tags when the block raises" do
          assert_raises(ArgumentError) { SemanticLogger.tagged("a", "b") { raise ArgumentError } }
          assert_empty SemanticLogger.tags
        end
      end

      describe ".tags" do
        it "returns a copy that the caller can change" do
          SemanticLogger.tagged("a") do
            tags = SemanticLogger.tags
            tags << "b"

            assert_equal ["a"], SemanticLogger.tags
          end
        end
      end

      describe ".named_tags" do
        it "returns a copy that the caller can change" do
          SemanticLogger.tagged(a: 1) do
            named_tags      = SemanticLogger.named_tags
            named_tags[:b]  = 2

            assert_equal({a: 1}, SemanticLogger.named_tags)
          end
        end

        it "lets a later Hash win" do
          SemanticLogger.tagged(user: "jack", id: 1) do
            SemanticLogger.tagged(user: "jill") do
              assert_equal({user: "jill", id: 1}, SemanticLogger.named_tags)
            end
          end
        end
      end

      describe ".pop_tags" do
        after do
          SemanticLogger.pop_tags(10)
        end

        it "returns the tags removed" do
          SemanticLogger.push_tags("a", "b", "c")

          assert_equal %w[b c], SemanticLogger.pop_tags(2)
          assert_equal ["a"], SemanticLogger.tags
        end

        it "removes every tag when asked for more than there are" do
          SemanticLogger.push_tags("a")

          assert_equal ["a"], SemanticLogger.pop_tags(3)
          assert_empty SemanticLogger.tags
        end

        it "returns nil when no tags were ever set on the fiber" do
          assert_nil Fiber.new { SemanticLogger.pop_tags }.resume
        end
      end

      describe ".pop_named_tags" do
        it "returns the Hashes removed" do
          SemanticLogger.push_named_tags(a: 1)
          SemanticLogger.push_named_tags(b: 2)

          assert_equal [{b: 2}], SemanticLogger.pop_named_tags
          assert_equal({a: 1}, SemanticLogger.named_tags)
        ensure
          SemanticLogger.pop_named_tags(10)
        end
      end

      describe "fibers" do
        it "each have their own tags" do
          SemanticLogger.tagged("outer") do
            assert_empty(Fiber.new { SemanticLogger.tags }.resume)
            assert_equal ["outer"], SemanticLogger.tags
          end
        end
      end
    end
  end
end
