require_relative "../test_helper"
require_relative "../signal_trap_helper"

class ThrottledCounterTest < Minitest::Test
  describe SemanticLogger::QueueProcessor::ThrottledCounter do
    let(:reports) { [] }

    def record(counter, count = 1, interval: 30)
      counter.record(count, interval: interval) { |unreported, seconds| reports << [unreported, seconds] }
    end

    # Runs the block while another thread holds the counter's lock, so that the occurrences recorded
    # in a signal trap meanwhile stay waiting, then releases it.
    def while_locked_elsewhere(counter)
      holding = Queue.new
      release = Queue.new
      holder  = Thread.new do
        counter.instance_variable_get(:@mutex).synchronize do
          holding << true
          release.pop
        end
      end
      holding.pop
      yield
    ensure
      release << true
      holder.join
    end

    # Waits until the condition holds, for 5 seconds at most.
    def wait_until
      deadline = Time.now + 5
      sleep(0.01) until yield || Time.now > deadline
    end

    it "measures the interval with the monotonic clock, unaffected by a change of the system clock" do
      counter = SemanticLogger::QueueProcessor::ThrottledCounter.new(reported_at: nil)
      record(counter)
      # The system clock steps back an hour, as NTP can, between two occurrences.
      Time.stub(:now, Time.now - 3_600) { record(counter, interval: 0) }

      assert_equal 2, reports.size
    end

    it "does not report early when the system clock steps forward" do
      counter = SemanticLogger::QueueProcessor::ThrottledCounter.new(reported_at: nil)
      record(counter)
      Time.stub(:now, Time.now + 3_600) { record(counter, interval: 30) }

      assert_equal 1, reports.size
    end

    it "counts every occurrence in the total" do
      counter = SemanticLogger::QueueProcessor::ThrottledCounter.new
      record(counter)
      record(counter, 4)

      assert_equal 5, counter.total
    end

    it "reports once the interval has passed since counting started" do
      started = SemanticLogger::QueueProcessor::ThrottledCounter.now - 60
      counter = SemanticLogger::QueueProcessor::ThrottledCounter.new(reported_at: started)
      record(counter, 2)
      record(counter, 3)

      assert_equal 1, reports.size
      assert_equal 2, reports.first[0]
      assert_in_delta 60, reports.first[1], 1
    end

    it "does not report within the interval" do
      counter = SemanticLogger::QueueProcessor::ThrottledCounter.new
      3.times { record(counter) }

      assert_empty reports
      assert_equal 3, counter.total
    end

    it "reports the first occurrence straight away when there is no previous report" do
      counter = SemanticLogger::QueueProcessor::ThrottledCounter.new(reported_at: nil)
      3.times { record(counter) }

      assert_equal [[1, nil]], reports
      assert_equal 3, counter.total
    end

    it "reports the occurrences since the previous report" do
      counter = SemanticLogger::QueueProcessor::ThrottledCounter.new(reported_at: nil)
      record(counter)
      record(counter, 2)
      record(counter, 3, interval: 0)

      assert_equal [1, 5], reports.map(&:first)
    end

    it "counts every occurrence recorded from many threads at once" do
      counter = SemanticLogger::QueueProcessor::ThrottledCounter.new(reported_at: nil)
      reported = Queue.new
      threads = Array.new(8) do
        Thread.new do
          1_000.times { counter.record(interval: 0) { |unreported, _seconds| reported << unreported } }
        end
      end
      threads.each(&:join)

      assert_equal 8_000, counter.total
      assert_equal 8_000, Array.new(reported.size) { reported.pop }.sum
    end

    it "counts an occurrence recorded while reporting, such as by the logger reported to" do
      counter = SemanticLogger::QueueProcessor::ThrottledCounter.new(reported_at: nil)
      counter.record(interval: 0) do |unreported, seconds|
        reports << [unreported, seconds]
        record(counter, interval: 0)
      end

      assert_equal 2, counter.total
      assert_equal [1, 1], reports.map(&:first)
    end

    # Ruby does not allow a Mutex to be locked in a signal trap.
    describe "in a signal trap" do
      include SignalTrapHelper

      it "counts an occurrence, in the total read outside the trap" do
        counter = SemanticLogger::QueueProcessor::ThrottledCounter.new

        recorded = in_signal_trap { record(counter, 2) }

        assert_nil recorded
        assert_equal 2, counter.total
      end

      it "reports the occurrences just after the trap, from a thread started for them" do
        counter = SemanticLogger::QueueProcessor::ThrottledCounter.new(reported_at: nil)
        in_signal_trap { record(counter, 2, interval: 0) }
        wait_until { reports.any? }

        assert_equal [[2, nil]], reports
        assert_equal 2, counter.total
      end

      it "starts one thread for all the occurrences recorded in a trap" do
        counter = SemanticLogger::QueueProcessor::ThrottledCounter.new(reported_at: nil)
        create  = Thread.method(:new)
        created = 0
        count   = lambda do |*args, &block|
          created += 1
          create.call(*args, &block)
        end
        while_locked_elsewhere(counter) do
          Thread.stub(:new, count) { in_signal_trap { 3.times { record(counter, interval: 0) } } }
        end
        wait_until { reports.any? }

        assert_equal 1, created
        assert_equal [[3, nil]], reports
      end

      it "leaves the occurrences to the next report when none is due just after the trap" do
        counter = SemanticLogger::QueueProcessor::ThrottledCounter.new
        in_signal_trap { record(counter, 2) }
        record(counter, interval: 0)

        assert_equal [3], reports.map(&:first)
        assert_equal 3, counter.total
      end

      it "leaves the occurrences not yet added in out of the total read in a trap" do
        counter = SemanticLogger::QueueProcessor::ThrottledCounter.new
        record(counter)
        total_in_trap = while_locked_elsewhere(counter) do
          in_signal_trap do
            record(counter)
            counter.total
          end
        end

        assert_equal 1, total_in_trap
        assert_equal 2, counter.total
      end
    end

    # As when a signal trap interrupts the thread while it holds the lock.
    it "counts an occurrence recorded by the thread that holds the lock" do
      counter = SemanticLogger::QueueProcessor::ThrottledCounter.new
      counter.instance_variable_get(:@mutex).synchronize { record(counter, 3) }

      assert_equal 3, counter.total
    end
  end
end
