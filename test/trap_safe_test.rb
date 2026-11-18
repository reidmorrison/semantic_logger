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

    describe ".in_trap?" do
      it "is false outside a signal trap" do
        refute_predicate SemanticLogger::TrapSafe, :in_trap?
      end

      it "is false on a thread that holds a Mutex" do
        refute(mutex.synchronize { SemanticLogger::TrapSafe.in_trap? })
      end

      it "is true in a signal trap" do
        in_trap = in_signal_trap { SemanticLogger::TrapSafe.in_trap? }

        refute_kind_of Exception, in_trap
        assert in_trap
      end
    end

    describe ".compute_if_absent" do
      let(:map) { Concurrent::Map.new }

      it "adds the block's value when the map holds none for the key, and returns it" do
        assert_equal :added, SemanticLogger::TrapSafe.compute_if_absent(map, :key) { :added }
        assert_equal :added, map[:key]
      end

      it "returns the value the map holds, without running the block" do
        map[:key] = :held
        ran       = false

        assert_equal :held, SemanticLogger::TrapSafe.compute_if_absent(map, :key) { ran = true }
        refute ran
      end

      it "returns the block's value in a signal trap, and adds it just after the trap" do
        value = in_signal_trap { SemanticLogger::TrapSafe.compute_if_absent(map, :key) { :added } }

        assert_equal :added, value
        deadline = Time.now + 5
        sleep(0.01) until map.key?(:key) || Time.now > deadline

        assert_equal :added, map[:key]
      end

      it "returns the value the map holds in a signal trap" do
        map[:key] = :held

        value = in_signal_trap { SemanticLogger::TrapSafe.compute_if_absent(map, :key) { :added } }

        assert_equal :held, value
      end
    end
  end
end
