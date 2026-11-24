require_relative "../test_helper"

class AsideTest < Minitest::Test
  describe SemanticLogger::QueueProcessor::Aside do
    let(:inbox) { SemanticLogger::QueueProcessor::Inbox.new(-1) }
    let(:dropped) { [] }
    let(:writing) { [true] }
    let(:written) { [] }
    let(:write) { ->(log) { written << log } }
    let(:aside) { aside_writing(write) }

    # Returns [Aside] one that writes each message with `write`.
    def aside_writing(write, into: inbox)
      SemanticLogger::QueueProcessor::Aside.new(into, -> { dropped << true }, -> { writing.first }, write) { true }
    end

    def queued = Array.new(inbox.queue.size) { inbox.queue.pop }

    it "adds the messages to the queue, in order, while no flush is under way" do
      assert aside.log(%w[a b])
      assert_equal %w[a b], queued
    end

    it "writes the messages logged aside while it flushes, then flushes again" do
      flushes = 0
      result  = aside.flush do
        flushes += 1
        aside.log(%w[a b]) if flushes == 1
        flushes
      end

      assert_equal 2, result
      assert_equal %w[a b], written
      assert_empty queued
    end

    it "adds the messages left to the queue once the thread can write no more" do
      write_once = lambda do |log|
        written << log
        writing[0] = false
      end
      once = aside_writing(write_once)
      once.flush { once.log(%w[a b c]) if written.empty? }

      assert_equal %w[a], written
      assert_equal %w[b c], queued
    end

    it "writes the others when writing one raises" do
      failing = lambda do |log|
        raise "boom" if log == "a"

        written << log
      end
      failed = aside_writing(failing)
      failed.flush { failed.log(%w[a b]) if written.empty? }

      assert_equal %w[b], written
    end

    it "flushes again at most FLUSHES times, then adds the rest to the queue" do
      flushes = 0
      aside.flush do
        flushes += 1
        aside.log(["again"])
      end

      assert_equal SemanticLogger::QueueProcessor::Aside::FLUSHES + 1, flushes
      assert_equal SemanticLogger::QueueProcessor::Aside::FLUSHES, written.size
      assert_equal %w[again], queued
    end

    it "counts each message dropped once none can be added" do
      capped = SemanticLogger::QueueProcessor::Inbox.new(1)
      capped.push("full", wait: false)
      stopped = SemanticLogger::QueueProcessor::Aside.new(capped, -> { dropped << true }, -> { true }, write) { false }
      stopped.log(%w[a b])
      deadline = Time.now + 5
      sleep(0.01) until dropped.size == 2 || Time.now > deadline

      assert_equal 2, dropped.size
    end

    it "leaves the messages set aside to the thread releasing them, which adds them after its own, in order" do
      # An Inbox that, as the first messages released are added, has another thread set some aside and
      # release them too, as #log does once it finds that the flush ended as it set them aside.
      racing = Class.new(SemanticLogger::QueueProcessor::Inbox) do
        attr_accessor :meanwhile

        def push_aside(items, otherwise, &)
          added = super
          during         = meanwhile
          self.meanwhile = nil
          during&.call
          added
        end
      end.new(-1)
      released = aside_writing(write, into: racing)
      sets     = released.instance_variable_get(:@logs)
      sizes    = []
      racing.meanwhile = lambda do
        Thread.new do
          sets << %w[c d]
          released.send(:release)
        end.join(5)
        sizes << racing.queue.size
      end
      sets << %w[a b]
      released.send(:release)

      assert_equal [2], sizes, "the other thread should have left its messages to the one releasing"
      assert_equal %w[a b c d], Array.new(racing.queue.size) { racing.queue.pop }
    end

    it "forgets, in a forked child, the messages set aside in the parent and the parent's flush" do
      aside.flush do
        aside.log(%w[parent])
        aside.instance_variable_set(:@pid, -1)
        aside.log(%w[child])

        assert_equal %w[child], queued, "the child adds its messages to the queue, since it is not flushing"
      end

      assert_empty written
    end
  end
end
