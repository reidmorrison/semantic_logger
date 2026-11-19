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

      it "returns the block's value in a signal trap, added by the time the trap returns" do
        value = in_signal_trap { SemanticLogger::TrapSafe.compute_if_absent(map, :key) { :added } }

        assert_equal :added, value
        assert_equal :added, map[:key]
      end

      it "adds the block's value just after a signal trap that interrupted a write to the map" do
        value = nil
        # The map holds its lock while it runs the block, here a trap.
        map.compute_if_absent(:other) do
          value = in_signal_trap { SemanticLogger::TrapSafe.compute_if_absent(map, :key) { :added } }

          refute map.key?(:key), "the value cannot be added before the write is over"
          :other
        end

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

    describe ".hand_off" do
      # Waits for a thread whose block raised IOError to finish.
      def join_failed(thread)
        thread.join(5)
      rescue IOError
        nil
      end

      it "returns the block's value from another thread in a signal trap" do
        value = in_signal_trap { SemanticLogger::TrapSafe.hand_off(5) { [mutex.synchronize { :locked }, Thread.current] } }

        assert_equal :locked, value.first
        refute_equal Thread.current, value.last
      end

      it "raises what the block raised, without reporting it" do
        _, stderr = capture_io do
          raised = in_signal_trap { SemanticLogger::TrapSafe.hand_off(5) { raise IOError, "cannot" } }

          assert_kind_of IOError, raised
        end

        assert_empty stderr
      end

      it "returns nil when the block has not finished in time, and lets it finish" do
        gate     = Queue.new
        finished = Queue.new
        value    = in_signal_trap do
          SemanticLogger::TrapSafe.hand_off(0.05) do
            gate.pop(timeout: 5)
            finished << true
          end
        end
        gate << true

        assert_nil value
        assert finished.pop(timeout: 5)
      end

      it "reports what the block raised after the trap stopped waiting" do
        gate      = Queue.new
        thread    = nil
        _, stderr = capture_io do
          value = in_signal_trap do
            SemanticLogger::TrapSafe.hand_off(0.01) do
              thread = Thread.current
              gate.pop(timeout: 5)
              raise IOError, "late failure"
            end
          end
          gate << true
          join_failed(thread)

          assert_nil value
        end

        assert_equal 1, stderr.scan("late failure").size
      end

      it "reports what the block raised when the caller is interrupted after the thread finished" do
        thread = Thread.new do
          Thread.current.report_on_exception = false
          raise IOError, "after the thread finished."
        end
        assert_raises(IOError) { thread.join(5) }
        token = Queue.new # empty: the thread took the token

        _, stderr = capture_io { SemanticLogger::TrapSafe.send(:report_outcome, thread, token, Queue.new) }

        assert_match(/terminated with exception.*after the thread finished\./m, stderr)
      end

      it "leaves the report to Ruby when the caller is interrupted before the thread finished" do
        token = Queue.new
        token << true

        _, stderr = capture_io { SemanticLogger::TrapSafe.send(:report_outcome, Thread.current, token, Queue.new) }

        assert_empty stderr
        assert_empty token, "the caller should take the token, so that the thread reports"
      end

      it "lets Ruby report what the block raised when the wait is interrupted" do
        started   = Queue.new
        _, stderr = capture_io do
          caller = Thread.new do
            SemanticLogger::TrapSafe.hand_off(5) do
              started << Thread.current
              sleep 0.2
              raise IOError, "after the interruption."
            end
          end
          worker = started.pop(timeout: 5)
          caller.raise(Interrupt)
          assert_raises(Interrupt) { caller.join }
          join_failed(worker)
        end

        assert_match(/after the interruption\./, stderr)
      end

      it "raises or reports what the block raised, never both, when it fails as the wait ends" do
        outcomes  = []
        threads   = Queue.new
        _, stderr = capture_io do
          in_signal_trap do
            50.times do |i|
              outcomes << SemanticLogger::TrapSafe.hand_off(0) do
                threads << Thread.current
                raise IOError, "failure #{i}."
              end
            rescue IOError
              outcomes << :raised
            end
          end
          50.times do
            thread = threads.pop(timeout: 5)
            flunk("a handed-off block did not start within 5 seconds") unless thread
            join_failed(thread)
          end
        end

        raised = outcomes.count(:raised)

        assert_equal 50 - raised, outcomes.count(nil)
        assert_equal 50 - raised, stderr.scan(/failure \d+\./).size
      end
    end
  end
end
