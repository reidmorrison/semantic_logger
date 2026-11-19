require_relative "../test_helper"

class InboxTest < Minitest::Test
  describe SemanticLogger::QueueProcessor::Inbox do
    let(:inbox) { SemanticLogger::QueueProcessor::Inbox.new(1) }

    it "has a queue capped at max_queue_size" do
      assert_instance_of SizedQueue, inbox.queue
      assert_equal 1, inbox.queue.max
      assert_predicate inbox, :capped?
    end

    it "has a queue that is not capped when max_queue_size is -1" do
      inbox = SemanticLogger::QueueProcessor::Inbox.new(-1)

      assert_instance_of Queue, inbox.queue
      refute_predicate inbox, :capped?
      assert(inbox.push(:first, wait: true) { flunk "must not wait" })
      assert inbox.push(:second, wait: false)
      assert_equal 2, inbox.queue.size
    end

    it "adds without waiting while there is room, and returns false once the queue is full" do
      assert inbox.push(:first, wait: false)
      refute inbox.push(:second, wait: false)
      assert_equal [:first], [inbox.queue.pop]
    end

    it "waits for room while the block returns true" do
      inbox.push(:first, wait: false)
      pushing = Thread.new { inbox.push(:second, wait: true) { true } }
      Thread.pass until pushing.status == "sleep"
      inbox.queue.pop

      assert pushing.value
      assert_equal :second, inbox.queue.pop
    end

    it "stops waiting for room once the block returns false, without adding" do
      inbox.push(:first, wait: false)
      asked = 0

      refute(inbox.push(:second, wait: true) { (asked += 1) < 2 })
      assert_equal 2, asked
      assert_equal 1, inbox.queue.size
    end

    it "asks the block as soon as the queue is full, before waiting for room" do
      inbox.push(:first, wait: false)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      refute(inbox.push(:second, wait: true) { false })
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
                      :<, SemanticLogger::QueueProcessor::Inbox::WAIT_CHECK_SECONDS / 2.0
    end

    it "does not ask the block while the queue has room" do
      assert(inbox.push(:first, wait: true) { flunk "must not be asked" })
    end

    it "adds the items in order on one other thread once the queue is full, without waiting" do
      inbox.push(:first, wait: false)

      assert(inbox.push_aside(%i[a b c], ->(_rest) { flunk "must be added" }) { true })
      assert_equal %i[first a b c], Array.new(4) { inbox.queue.pop(timeout: 5) }
    end

    it "passes the items not added to otherwise, on another thread, once the block returns false" do
      given = Queue.new

      assert(inbox.push_aside(%i[a b], ->(rest) { given << [rest, Thread.current] }) { false })
      rest, thread = given.pop(timeout: 5)

      assert_equal %i[a b], rest
      refute_equal Thread.current, thread
      assert_empty inbox.queue
    end

    it "takes the entries of a class off the queue, and adds the others back in order" do
      inbox = SemanticLogger::QueueProcessor::Inbox.new(5)
      [1, :a, 2, :b].each { |entry| inbox.push(entry, wait: false) }

      assert_equal %i[a b], inbox.take(Symbol)
      assert_equal [1, 2], Array.new(2) { inbox.queue.pop(timeout: 0) }
      assert_empty inbox.queue
    end

    it "yields each entry it cannot add back, such as when a waiting thread took its place" do
      inbox = SemanticLogger::QueueProcessor::Inbox.new(5)
      [1, :a, 2].each { |entry| inbox.push(entry, wait: false) }
      lost  = []
      push  = inbox.method(:push)

      inbox.stub(:push, ->(entry, **options) { entry == 2 ? false : push.call(entry, **options) }) do
        assert_equal [:a], inbox.take(Symbol) { |entry| lost << entry }
      end

      assert_equal [2], lost
      assert_equal [1], Array.new(1) { inbox.queue.pop(timeout: 0) }
    end

    it "adds to the queue it is given" do
      queue = SizedQueue.new(1)

      assert(inbox.push(:first, queue, wait: true) { true })
      assert_equal :first, queue.pop
      assert_empty inbox.queue
    end

    it "belongs to the process that created it" do
      refute_predicate inbox, :forked?
      inbox.instance_variable_set(:@pid, -1)

      assert_predicate inbox, :forked?
    end

    it "closes its queue and creates an empty one, which belongs to this process, when recreated" do
      inbox.instance_variable_set(:@pid, -1)
      queue = inbox.queue
      queue << :parent
      inbox.recreate

      assert_predicate queue, :closed?
      assert_empty inbox.queue
      assert_instance_of SizedQueue, inbox.queue
      refute_predicate inbox, :forked?
    end
  end
end
