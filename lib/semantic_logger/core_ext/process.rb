module SemanticLogger
  module CoreExt
    # Reopen all appenders in the child process after a fork.
    #
    # Prepended onto `Process.singleton_class` when Semantic Logger is loaded.
    # Enabled by default; opt out with `SemanticLogger.reopen_on_fork = false`.
    #
    # `Process._fork` (Ruby 3.1+) is the single method that every fork path routes
    # through (`Kernel#fork`, `Process.fork`, `IO.popen`, `Kernel#system`, and
    # backticks), so overriding it covers them all with one hook.
    #
    # Note: both `_fork` and `daemon` must be overridden to reliably restart the
    # appender thread, since `Process.daemon` does not route through `_fork`
    # (https://bugs.ruby-lang.org/issues/18911). Do not collapse this down to only
    # `_fork`.
    module Process
      # `_fork` runs in both the parent and the child. It returns 0 in the child
      # and the child's pid in the parent, so only reopen in the child. Reopening
      # in the parent would needlessly recreate its queue and worker thread,
      # risking the loss of messages still on the queue.
      def _fork
        child_pid = super
        SemanticLogger.reopen if child_pid.zero? && SemanticLogger.reopen_on_fork?
        child_pid
      end

      # `Process.daemon` does not route through `_fork`, so reopen explicitly. Once
      # it returns, the caller is running as the daemon (child) process.
      def daemon(...)
        super.tap { SemanticLogger.reopen if SemanticLogger.reopen_on_fork? }
      end
    end
  end
end
