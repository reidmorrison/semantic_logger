require_relative "../test_helper"

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
  end
end
