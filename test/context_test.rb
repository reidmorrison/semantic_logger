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

        it "restore the tags that were popped inside the block when it exits" do
          SemanticLogger.push_tags("a")
          SemanticLogger.tagged("b", "c") { SemanticLogger.pop_tags(3) }

          assert_equal ["a"], SemanticLogger.tags
        ensure
          SemanticLogger.pop_tags(10)
        end

        it "restore the named tags that were popped inside the block when it exits" do
          SemanticLogger.push_named_tags(b: 2)
          SemanticLogger.tagged(a: 1) { SemanticLogger.pop_named_tags(2) }

          assert_equal({b: 2}, SemanticLogger.named_tags)
        ensure
          SemanticLogger.pop_named_tags(10)
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

      describe "SemanticLogger.context" do
        it "is a frozen snapshot of the tags, named tags, and silence level" do
          context = nil
          SemanticLogger.tagged("a", "b") do
            SemanticLogger.tagged(user: "jack") do
              SemanticLogger.tagged(id: 1) { SemanticLogger.silence(:warn) { context = SemanticLogger.context } }
            end
          end

          assert_predicate context, :frozen?
          assert_equal %w[a b], context.tags
          assert_predicate context.tags, :frozen?
          assert_equal({user: "jack", id: 1}, context.named_tags)
          assert_predicate context.named_tags, :frozen?
          assert_equal :warn, context.silence
        end

        it "does not change when the tags change afterwards" do
          SemanticLogger.tagged("a") do
            context = SemanticLogger.context
            SemanticLogger.push_tags("b")

            assert_equal ["a"], context.tags
          end
        end

        it "is empty without tags" do
          context = SemanticLogger.context

          assert_empty context.tags
          assert_empty context.named_tags
          assert_nil context.silence
        end

        it "does not include with_level overrides" do
          logger.level = :info
          context      = logger.with_level(:trace) { SemanticLogger.context }

          assert_equal :info, Thread.new { SemanticLogger.with_context(context) { logger.level } }.value
        end
      end

      describe "SemanticLogger.with_context" do
        let(:context) do
          SemanticLogger.tagged("request") do
            SemanticLogger.tagged(request_id: 42) { SemanticLogger.silence(:error) { SemanticLogger.context } }
          end
        end

        it "applies the context in another thread" do
          tags, named_tags, level_index = Thread.new do
            SemanticLogger.with_context(context) do
              [SemanticLogger.tags, SemanticLogger.named_tags, SemanticLogger.default_level_index]
            end
          end.value

          assert_equal ["request"], tags
          assert_equal({request_id: 42}, named_tags)
          assert_equal Levels.index(:error), level_index
        end

        it "applies the context to log entries" do
          log = Fiber.new { SemanticLogger.with_context(context) { Log.new("Test", :info) } }.resume

          assert_equal ["request"], log.tags
          assert_equal({request_id: 42}, log.named_tags)
        end

        it "applies the context within an Enumerator's fiber" do
          snapshot   = context
          enumerator = Enumerator.new do |yielder|
            SemanticLogger.with_context(snapshot) { yielder << SemanticLogger.tags }
          end

          assert_equal ["request"], enumerator.next
        end

        it "replaces the fiber's own context, and restores it afterwards" do
          snapshot = context
          SemanticLogger.tagged("own") do
            SemanticLogger.tagged(own: true) do
              SemanticLogger.with_context(snapshot) do
                assert_equal ["request"], SemanticLogger.tags
                assert_equal({request_id: 42}, SemanticLogger.named_tags)
              end

              assert_equal ["own"], SemanticLogger.tags
              assert_equal({own: true}, SemanticLogger.named_tags)
              assert_nil Context.silence_index
            end
          end
        end

        it "restores the fiber's own context when the block raises" do
          assert_raises(ArgumentError) { SemanticLogger.with_context(context) { raise ArgumentError } }
          assert_empty SemanticLogger.tags
          assert_empty SemanticLogger.named_tags
          assert_nil Context.silence_index
        end

        it "lets tags be added within the block" do
          SemanticLogger.with_context(context) do
            SemanticLogger.tagged("job") { assert_equal %w[request job], SemanticLogger.tags }
          end
        end

        it "returns the result of the block" do
          assert_equal 42, SemanticLogger.with_context(context) { 42 }
        end

        it "rejects anything other than a context" do
          error = assert_raises(ArgumentError) { SemanticLogger.with_context(tags: ["a"]) { 1 } }

          assert_match(/SemanticLogger::Context/, error.message)
        end
      end

      describe ".new" do
        it "copies and freezes the supplied tags" do
          tags    = ["a"]
          context = Context.new(tags: tags, named_tags: {id: 1}, silence: "warn")
          tags << "b"

          assert_equal ["a"], context.tags
          assert_predicate context.named_tags, :frozen?
          assert_equal :warn, context.silence
        end

        it "rejects tags that are not an Array" do
          assert_raises(ArgumentError) { Context.new(tags: "a") }
        end

        it "rejects named tags that are not a Hash" do
          assert_raises(ArgumentError) { Context.new(named_tags: ["a"]) }
        end

        it "rejects an invalid silence level" do
          assert_raises(ArgumentError) { Context.new(silence: :loud) }
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
