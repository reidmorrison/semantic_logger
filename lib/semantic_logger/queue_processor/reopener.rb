module SemanticLogger
  class QueueProcessor
    # Internal: reopens the appender of a queue processor, on its worker thread, once asked.
    #
    # The worker thread asks it before each write, so the appender is never reopened while it is
    # writing, such as a file being closed under a write, or a connection ended under a request.
    # Nor is it reopened on the thread that asks, often a signal trap after a log rotation, where
    # Ruby does not allow a Mutex to be locked, as connecting with a timeout does.
    #
    # It knows whether a reopen has been asked for, and reports a reopen that fails to the internal
    # logger. Asked from any thread, and from a signal trap, so it records that on a Queue.
    class Reopener
      def initialize(appender, reporter)
        @appender = appender
        @reporter = reporter
        @asked    = Queue.new
      end

      # Ask for the appender to be reopened before the worker thread writes again.
      def ask
        @asked << true
      end

      # Reopen the appender, if asked to since it was last reopened. Called by the worker thread,
      # between writes. A reopen that fails is reported rather than raised: the appender keeps what
      # it had, and writing to it then fails, or not, as it would have.
      def reopen_if_asked
        return if @asked.empty?

        @asked.clear
        @appender.reopen if @appender.respond_to?(:reopen)
      rescue StandardError => e
        @reporter.log(:error, "Async: Failed to reopen the appender", e)
      end
    end
  end
end
