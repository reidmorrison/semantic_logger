require_relative "test_helper"
require_relative "signal_trap_helper"

class TrapSafeTest < Minitest::Test
  describe SemanticLogger::TrapSafe do
    include SignalTrapHelper

    let(:mutex) { Mutex.new }

    describe ".try_synchronize" do
      it "runs the block holding the mutex, and returns true" do
        held = nil

        assert SemanticLogger::TrapSafe.try_synchronize(mutex) { held = mutex.owned? }
        assert held
        refute_predicate mutex, :locked?
      end

      it "returns false without running the block on the thread that holds the mutex" do
        ran = false
        result = mutex.synchronize { SemanticLogger::TrapSafe.try_synchronize(mutex) { ran = true } }

        refute result
        refute ran
      end

      # Ruby does not allow a Mutex to be locked in a signal trap.
      it "returns false without running the block in a signal trap" do
        ran = false
        result = in_signal_trap { SemanticLogger::TrapSafe.try_synchronize(mutex) { ran = true } }

        refute result
        refute ran
      end

      it "raises a ThreadError raised by the block" do
        assert_raises(ThreadError) do
          SemanticLogger::TrapSafe.try_synchronize(mutex) { raise ThreadError, "from the block" }
        end
        refute_predicate mutex, :locked?
      end
    end
  end
end
