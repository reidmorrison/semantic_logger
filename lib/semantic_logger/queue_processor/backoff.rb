module SemanticLogger
  class QueueProcessor
    # Internal: how long the worker thread of a queue processor waits, after it could not write to
    # the destination of its appender, before it writes again, and when it gives up instead.
    #
    # It knows how many times in a row writing has failed, how many times the worker thread may retry
    # before it gives up (async_max_retries), how many requests, such as a flush or close, are
    # waiting for the worker thread to run them, and whether the process is exiting. Each back-off
    # waits a second longer than the one before, except while the worker thread is waited on, by a
    # request or the exiting process, which must not wait out back-offs: then the worker thread does
    # not wait at all, submitting a request or exiting ends the back-off under way, and once the
    # destination fails, the worker thread gives up on the messages queued ahead of the next request
    # (see #give_up?).
    #
    # Requests are submitted from other threads, and from a signal trap, where Ruby does not allow a
    # Mutex to be locked, so it counts them, and waits, on Queues.
    class Backoff
      # Returns [Integer] the number of times the worker thread retries after a failure, before it
      # gives up, or -1 to retry for ever.
      attr_reader :max_retries

      # Returns [Integer] the number of failures in a row, which is also how many seconds the next
      # back-off waits.
      attr_reader :retry_count

      def initialize(max_retries)
        @max_retries = max_retries
        @retry_count = 0
        # One entry for each request waiting.
        @requests    = Queue.new
        # Holds an entry once a request has been submitted since the back-off under way began. One is
        # enough to end it, so that submitting many requests without a failure does not add up.
        @interrupts  = SizedQueue.new(1)
        @exiting     = false
        @gave_up     = nil
      end

      # Start counting afresh, once writing succeeds.
      def reset
        @retry_count = 0
      end

      # Start afresh for a worker thread new to the process, after a fork: it has not failed yet, the
      # requests counted as waiting were on the queue of the parent process, which the child
      # replaces, and the child is not exiting, even when the parent was, such as when another thread
      # forked while the parent flushed at exit.
      def restart
        reset
        @requests.clear
        @exiting = false
        @gave_up = nil
      end

      # Count a failure. Returns whether the worker thread retries after it, or false once it has
      # retried max_retries times in a row.
      def retry?
        return false unless max_retries == -1 || retry_count < max_retries

        @retry_count += 1
        true
      end

      # Returns [Integer|String] the number of retries the worker thread makes at most, for a report.
      def limit = max_retries == -1 ? "unlimited" : max_retries

      # Waits retry_count seconds, unless the worker thread is waited on, or until it is.
      #
      # The interruptions from before are cleared before it checks whether it is waited on, so that a
      # request submitted, or the process exiting, in between either is seen or interrupts the wait.
      def wait
        @interrupts.clear
        @interrupts.pop(timeout: retry_count) unless waited_on?
      end

      # Called before a request is added to the queue: it is waiting until #request_done, and ends the
      # back-off under way. Never waits, since an interruption already queued ends it as well.
      def request_submitted
        @requests << true
        @interrupts.push(true, timeout: 0)
      end

      # Called once for each request submitted, once it has run or will not (see Request#done). The
      # worker thread no longer gives up on the messages queued after it (see #give_up?).
      def request_done
        @requests.pop(timeout: 0)
        @gave_up = nil
      end

      # Tell it whether the process is exiting: true before the flush at exit, and false once that
      # flush has returned, since a test framework can run its tests in a later at_exit hook. While
      # the process exits, the worker thread is waited on, as though a request were waiting, and the
      # back-off under way ends. Once it no longer exits, the worker thread gives up no more, unless a
      # request is still waiting (see #gave_up). Called from the exiting thread, which may be in a
      # signal trap, so it takes no lock either.
      def exiting=(exiting)
        @exiting = exiting
        if exiting
          @interrupts.push(true, timeout: 0)
        elsif !waited_on?
          @gave_up = nil
        end
      end

      # Whether the worker thread is waited on: a request, such as a flush or close, is waiting for
      # it to run it, or the process is exiting. It then neither waits out back-offs nor writes again
      # what the destination failed.
      def waited_on? = @exiting || request_waiting?

      # Whether a request, such as a flush or close, is waiting for the worker thread to run it. The
      # thread that submitted it may be the worker thread of the queue processor that writes to this
      # one's appender, which then waits for this worker thread (see QueueProcessor#holding_up?).
      def request_waiting? = !@requests.empty?

      # Called once the destination failed. While the worker thread is waited on, it gives up on the
      # messages queued ahead of the next request, such as a flush, and discards them without writing
      # them (see #gave_up), since each could take as long to fail, such as the open_timeout of a
      # server that does not answer. While the process exits, it does so as well before the flush at
      # exit reaches the queue. Once a request has run (see #request_done), it writes the next
      # message once more, even while the process exits, and gives up again if that fails. So
      # returns true, having recorded the exception, for the worker thread to carry on straight
      # away, without backing off or counting a retry. Otherwise returns false.
      def give_up?(exception)
        return false unless waited_on?

        @gave_up = exception
        true
      end

      # Returns the exception with which the destination failed while the worker thread was waited
      # on (see #give_up?), while the messages it takes off the queue are to be discarded: until a
      # request has run, or the worker thread is no longer waited on. Otherwise nil.
      def gave_up
        return unless @gave_up
        return @gave_up if waited_on?

        @gave_up = nil
      end
    end
  end
end
