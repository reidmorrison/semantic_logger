require_relative "../test_helper"

class HeldWriteTest < Minitest::Test
  describe SemanticLogger::QueueProcessor::HeldWrite do
    let(:held) { SemanticLogger::QueueProcessor::HeldWrite.new }

    # Writes the messages held again, failing, so that the block holds them again, as the queue
    # processor does when the destination fails them once more, answering the write unless
    # `answered` is false. Returns whether they were held.
    def resend_failing(answered: true)
      held_again = nil
      held.resend { |logs| held_again = held.hold(logs, answered: answered) }
      held_again
    end

    it "holds nothing at first" do
      assert_nil held.release
    end

    it "yields the messages held to write them again, and forgets them once written" do
      held.hold(%i[first second], answered: true)
      yielded = nil
      held.resend { |logs| yielded = logs }

      assert_equal %i[first second], yielded
      held.resend { flunk "the messages were written" }
    end

    it "does not yield when nothing is held" do
      held.resend { flunk "nothing is held" }
    end

    it "holds the same messages again until the destination has answered them MAX_RESENDS times more" do
      assert held.hold([:entry], answered: true)
      results = Array.new(SemanticLogger::QueueProcessor::HeldWrite::MAX_RESENDS) { resend_failing }

      assert_equal [true, true, false], results
      assert_nil held.release
    end

    it "holds the messages again whenever the destination was not reached, without counting it" do
      assert held.hold([:entry], answered: false)

      assert_equal [true] * 10, Array.new(10) { resend_failing(answered: false) }
      assert_equal [true, true, true, false], Array.new(4) { resend_failing }
    end

    it "keeps the count of answers across failures that did not reach the destination" do
      held.hold([:entry], answered: true)

      assert_equal [true, true, true, true, false],
                   [resend_failing, resend_failing(answered: false), resend_failing(answered: false),
                    resend_failing, resend_failing]
    end

    it "counts afresh for the next messages held" do
      held.hold([:first], answered: true)
      3.times { resend_failing }

      assert held.hold([:second], answered: true)
      assert_equal [true, true, false], Array.new(3) { resend_failing }
    end

    it "counts afresh once the messages held are written" do
      held.hold([:first], answered: true)
      resend_failing
      held.resend { |_logs| nil }

      assert held.hold([:second], answered: true)
      assert_equal [true, true, false], Array.new(3) { resend_failing }
    end

    it "forgets the messages held, and the count, when released" do
      held.hold([:first], answered: true)
      resend_failing

      assert_equal [:first], held.release
      assert_nil held.release
      assert held.hold([:second], answered: true)
      assert_equal [true, true, false], Array.new(3) { resend_failing }
    end

    it "keeps the messages it holds again when the block raises" do
      held.hold([:first], answered: true)

      assert_raises(IOError) do
        held.resend do |logs|
          held.hold(logs, answered: true)
          raise IOError, "destination unavailable"
        end
      end
      assert_equal [true, false], Array.new(2) { resend_failing }
    end
  end
end
