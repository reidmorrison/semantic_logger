require_relative "../test_helper"
require_relative "../signal_trap_helper"

class ThrottledCounterTest < Minitest::Test
  describe SemanticLogger::QueueProcessor::ThrottledCounter do
    let(:reports) { [] }

    def record(counter, count = 1, interval: 30)
      counter.record(count, interval: interval) { |unreported, seconds| reports << [unreported, seconds] }
    end

    it "counts every occurrence in the total" do
      counter = SemanticLogger::QueueProcessor::ThrottledCounter.new
      record(counter)
      record(counter, 4)

      assert_equal 5, counter.total
    end

    it "reports once the interval has passed since counting started" do
      counter = SemanticLogger::QueueProcessor::ThrottledCounter.new(reported_at: Time.now - 60)
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

      it "reports the occurrences with the next report outside the trap" do
        counter = SemanticLogger::QueueProcessor::ThrottledCounter.new(reported_at: nil)
        in_signal_trap { record(counter, 2, interval: 0) }

        assert_empty reports, "a report is not made in the trap"
        record(counter, interval: 0)

        assert_equal [3], reports.map(&:first)
        assert_equal 3, counter.total
      end

      it "leaves the occurrences recorded in a trap out of the total read in a trap" do
        counter = SemanticLogger::QueueProcessor::ThrottledCounter.new
        record(counter)
        total_in_trap = in_signal_trap do
          record(counter)
          counter.total
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
