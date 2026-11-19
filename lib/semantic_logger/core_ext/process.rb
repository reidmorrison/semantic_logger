module SemanticLogger
  module CoreExt
    # Reopen all appenders in the child process after a fork.
    #
    # Prepended onto `Process.singleton_class` when Semantic Logger is loaded.
    # Enabled by default; opt out with `SemanticLogger.reopen_on_fork = false`.
    #
    # `Process._fork` (Ruby 3.1+) is the method that every fork of the Ruby process
    # routes through (`Kernel#fork`, `Process.fork`, and `IO.popen("-")`), so
    # overriding it covers them all with one hook. `Kernel#system`, backticks,
    # `spawn`, and `IO.popen` with a command do not call it: they run another
    # program, which does not inherit Semantic Logger.
    #
    # It can also run in a signal trap, such as one that forks, where Ruby does
    # not allow a Mutex to be locked: pausing the thread that receives the entries
    # of other Ractors locks none, and neither does reopening in the child. In
    # synchronous mode, a thread that the trap starts reopens the appenders that
    # have no thread of their own (see SyncProcessor#reopen).
    #
    # Note: both `_fork` and `daemon` must be overridden to reliably restart the
    # appender thread, since `Process.daemon` does not route through `_fork`
    # (https://bugs.ruby-lang.org/issues/18911). Do not collapse this down to only
    # `_fork`.
    module Process
      # Runs the block, which forks, with Semantic Logger ready for the fork: on Ruby 4.0 and later,
      # while the thread that receives log entries from other Ractors is paused (see
      # RactorReceiver.pause).
      def self.pause_for_fork(&)
        SemanticLogger::RactorSupport.enabled? ? SemanticLogger::RactorReceiver.pause(&) : yield
      end

      # `_fork` runs in both the parent and the child. It returns 0 in the child
      # and the child's pid in the parent, so only reopen in the child. Reopening
      # in the parent would needlessly recreate its queue and worker thread,
      # risking the loss of messages still on the queue.
      def _fork
        child_pid = Process.pause_for_fork { super }
        SemanticLogger.reopen if child_pid.zero? && SemanticLogger.reopen_on_fork?
        child_pid
      end

      # `Process.daemon` does not route through `_fork`, so reopen explicitly. Once
      # it returns, the caller is running as the daemon (child) process.
      def daemon(...)
        Process.pause_for_fork { super }.tap { SemanticLogger.reopen if SemanticLogger.reopen_on_fork? }
      end
    end
  end
end
