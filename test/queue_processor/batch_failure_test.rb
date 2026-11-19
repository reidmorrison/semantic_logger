require_relative "../test_helper"

class BatchFailureTest < Minitest::Test
  describe SemanticLogger::QueueProcessor::BatchFailure do
    let(:logs) { %i[first second third fourth] }
    let(:error) { SemanticLogger::Subscriber::FormatError.new("Could not format") }

    # An appender that answers the batch questions as given, and implements none it is not given.
    def appender(all_or_nothing: true, **answers)
      appender = Object.new
      appender.define_singleton_method(:batch_all_or_nothing?) { all_or_nothing }
      answers.each_pair { |name, answer| appender.define_singleton_method(name) { |_exception| answer } }
      appender
    end

    def failure(appender, batch = logs) = SemanticLogger::QueueProcessor::BatchFailure.new(appender, batch, error)

    def assert_failure(failure, written:, discarded:, parts:)
      assert_equal written, failure.written
      assert_equal discarded, failure.discarded
      assert_equal parts, failure.parts
    end

    it "splits an all or nothing batch in half" do
      assert_failure failure(appender), written: 0, discarded: [], parts: [%i[first second], %i[third fourth]]
    end

    it "discards a single message" do
      assert_failure failure(appender, %i[first]), written: 0, discarded: %i[first], parts: []
    end

    it "discards a batch that is not all or nothing" do
      assert_failure failure(appender(all_or_nothing: false)), written: 0, discarded: logs, parts: []
    end

    it "discards an all or nothing batch at once when the error fails any batch" do
      assert_failure failure(appender(fails_any_batch?: true)), written: 0, discarded: logs, parts: []
    end

    it "counts those before the rejected message as written, discards it, and writes those after it again" do
      assert_failure failure(appender(rejected_entry: 1)),
                     written: 1, discarded: %i[second], parts: [%i[third fourth]]
    end

    it "does so for a batch that is not all or nothing too" do
      assert_failure failure(appender(all_or_nothing: false, rejected_entry: 0)),
                     written: 0, discarded: %i[first], parts: [%i[second third fourth]]
    end

    it "writes nothing again when the last message is rejected" do
      assert_failure failure(appender(rejected_entry: 3)), written: 3, discarded: %i[fourth], parts: []
    end

    it "discards the rejected message and every one after it when the error fails any batch" do
      assert_failure failure(appender(rejected_entry: 2, fails_any_batch?: true)),
                     written: 2, discarded: %i[third fourth], parts: []
    end

    [nil, -1, 4, "1", 1.0].each do |rejected|
      it "ignores a rejected message, #{rejected.inspect}, that is not in the batch" do
        assert_failure failure(appender(rejected_entry: rejected)),
                       written: 0, discarded: [], parts: [%i[first second], %i[third fourth]]
      end
    end
  end
end
