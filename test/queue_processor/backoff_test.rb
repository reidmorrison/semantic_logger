require_relative "../test_helper"
require_relative "../signal_trap_helper"

class BackoffTest < Minitest::Test
  describe SemanticLogger::QueueProcessor::Backoff do
    include SignalTrapHelper

    let(:backoff) { SemanticLogger::QueueProcessor::Backoff.new(2) }

    # Runs #wait on another thread, and returns that thread.
    def waiting
      thread = Thread.new { backoff.wait }
      Thread.pass until thread.status == "sleep" || !thread.alive?
      thread
    end

    it "retries up to max_retries times in a row, counting each failure" do
      assert_predicate backoff, :retry?
      assert_predicate backoff, :retry?
      refute_predicate backoff, :retry?
      assert_equal 2, backoff.retry_count
      assert_equal 2, backoff.limit
    end

    it "retries for ever when max_retries is -1" do
      backoff = SemanticLogger::QueueProcessor::Backoff.new(-1)

      assert_predicate(Array.new(1_000) { backoff.retry? }, :all?)
      assert_equal "unlimited", backoff.limit
    end

    it "counts afresh once reset" do
      2.times { backoff.retry? }
      backoff.reset

      assert_equal 0, backoff.retry_count
      assert_predicate backoff, :retry?
    end

    it "waits retry_count seconds, until a request is submitted" do
      2.times { backoff.retry? }
      thread = waiting

      refute thread.join(0.2), "the back-off should still be waiting"
      backoff.request_submitted

      assert thread.join(1), "a request should end the back-off"
      assert_predicate backoff, :waited_on?
    end

    it "does not wait while a request is waiting" do
      backoff.retry?
      backoff.request_submitted
      backoff.request_submitted
      backoff.request_done

      assert waiting.join(0.5), "the back-off should not wait"
    end

    it "waits once the requests have run, despite their having ended an earlier back-off" do
      backoff.retry?
      backoff.request_submitted
      backoff.request_done

      refute_predicate backoff, :waited_on?
      refute waiting.join(0.2), "the back-off should wait"
    end

    it "forgets the requests counted as waiting, and counts afresh, on a restart after a fork" do
      2.times { backoff.retry? }
      backoff.request_submitted
      backoff.restart

      refute_predicate backoff, :waited_on?
      assert_equal 0, backoff.retry_count
    end

    it "keeps at most one interruption, however many requests are submitted without a back-off" do
      1_000.times do
        backoff.request_submitted
        backoff.request_done
      end

      assert_equal 1, backoff.instance_variable_get(:@interrupts).size
      refute_predicate backoff, :waited_on?
    end

    it "submits a request in a signal trap, ending the back-off under way" do
      backoff.retry?
      thread  = waiting
      results = Array.new(2) { in_signal_trap { backoff.request_submitted } }

      refute(results.any?(StandardError))
      assert thread.join(1), "a request submitted in a signal trap should end the back-off"
      assert_predicate backoff, :waited_on?
    end

    it "ignores a request done that was not submitted" do
      backoff.request_done

      refute_predicate backoff, :waited_on?
    end

    it "ends the back-off under way, and does not wait, while the process exits" do
      2.times { backoff.retry? }
      thread          = waiting
      backoff.exiting = true

      assert thread.join(1), "exiting should end the back-off"
      assert_predicate backoff, :waited_on?
      assert waiting.join(0.5), "the back-off should not wait while the process exits"
    end

    it "waits again once the process no longer exits" do
      backoff.retry?
      backoff.exiting = true
      backoff.exiting = false

      refute_predicate backoff, :waited_on?
      refute waiting.join(0.2), "the back-off should wait"
    end

    it "is told that the process exits in a signal trap" do
      backoff.retry?
      thread = waiting
      told   = in_signal_trap do
        backoff.exiting = true
        :told
      end

      assert_equal :told, told
      assert thread.join(1), "exiting should end the back-off"
    end

    it "gives up after a failure only while waited on" do
      error = IOError.new("destination unavailable")

      refute backoff.give_up?(error)
      assert_nil backoff.gave_up
      backoff.request_submitted

      assert backoff.give_up?(error)
      assert_same error, backoff.gave_up
    end

    it "stops giving up once a request has run" do
      2.times { backoff.request_submitted }
      backoff.give_up?(IOError.new("destination unavailable"))
      backoff.request_done

      assert_predicate backoff, :waited_on?, "the second request should still be waiting"
      assert_nil backoff.gave_up
    end

    it "gives up while the process exits, until it no longer does" do
      backoff.exiting = true
      error           = IOError.new("destination unavailable")

      assert backoff.give_up?(error)
      assert_same error, backoff.gave_up
      backoff.exiting = false
      backoff.exiting = true

      assert_nil backoff.gave_up, "exiting again should not give up before a failure"
    end

    it "forgets that it gave up on a restart after a fork" do
      backoff.exiting = true
      backoff.give_up?(IOError.new("destination unavailable"))
      backoff.restart

      assert_nil backoff.gave_up
    end
  end
end
