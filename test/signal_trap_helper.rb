# Runs code in a signal trap, where Ruby does not allow a Mutex to be locked, for the tests of what
# an application can call from one, such as a trap that reopens the log files after a rotation.
module SignalTrapHelper
  # Runs the block in a handler trapping USR1, and returns what it returned, or the StandardError it
  # raised. Skips the test where USR1 is not available.
  def in_signal_trap(&)
    skip "the USR1 signal is not available" unless Signal.list.key?("USR1")

    trap_usr1(&)
  end

  private

  def trap_usr1
    result   = nil
    handled  = false
    previous = Signal.trap("USR1") do
      result = yield
    rescue StandardError => e
      result = e
    ensure
      handled = true
    end
    Process.kill("USR1", Process.pid)
    deadline = Time.now + 5
    sleep(0.01) until handled || Time.now > deadline

    assert handled, "the signal trap should have run"
    result
  ensure
    Signal.trap("USR1", previous) if previous
  end
end
