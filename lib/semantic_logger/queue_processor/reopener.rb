module SemanticLogger
  class QueueProcessor
    # Internal: reopens the appender of a queue processor, on its worker thread, once asked.
    #
    # The worker thread asks it between writes, so the appender is never reopened while it is
    # writing, such as a file being closed under a write, or a connection ended under a request.
    # Nor is it reopened on the thread that asks, often a signal trap after a log rotation, where
    # Ruby does not allow a Mutex to be locked, as connecting with a timeout does.
    #
    # It knows whether a reopen has been asked for, and reports a reopen that fails to the internal
    # logger. Asked from any thread, and from a signal trap, so it records that on a Queue.
    class Reopener
      def initialize(appender, reporter)
        @appender  = appender
        @reporter  = reporter
        @asked     = Queue.new
        @reopening = false
      end

      # Ask for the appender to be reopened before the worker thread writes again.
      def ask
        @asked << true
      end

      # Returns [true|false] whether a reopen has been asked for and the worker thread has not yet
      # finished it, including one that it is running. Reads only a Queue and a flag, so that it can
      # be called from any thread, or a signal trap.
      def pending? = @reopening || !@asked.empty?

      # Reopen the appender, if asked to since it was last reopened. Called by the worker thread,
      # between writes. A reopen that fails is reported rather than raised, whatever the exception,
      # as Appenders#reopen reports it, so that one that is not a StandardError, such as a LoadError
      # or NotImplementedError, does not stop the worker thread for good: the appender keeps what it
      # had, and writing to it then fails, or not, as it would have.
      #
      # Returns nil, or the SystemStackError when reopening overflowed the stack, so that the worker
      # thread hands over to a new one, since it must not overflow its stack again: on macOS a second
      # stack overflow on the same thread crashes Ruby.
      def reopen_if_asked
        return if @asked.empty?

        @reopening = true
        @asked.clear
        @appender.reopen if @appender.respond_to?(:reopen)
        nil
      rescue Exception => e
        @reporter.log(:error, "Async: Failed to reopen the appender", e)
        e if e.is_a?(SystemStackError)
      ensure
        @reopening = false
      end
    end
  end
end
