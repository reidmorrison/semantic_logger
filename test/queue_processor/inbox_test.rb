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

      refute(inbox.push(:second, wait: true) { (asked += 1) > 1 })
      assert_equal 1, asked
      assert_equal 1, inbox.queue.size
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
