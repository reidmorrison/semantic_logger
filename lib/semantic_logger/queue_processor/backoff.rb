module SemanticLogger
  class QueueProcessor
    # Internal: how long the worker thread of a queue processor waits, after it could not write to
    # the destination of its appender, before it writes again, and when it gives up instead.
    #
    # It knows how many times in a row writing has failed, how many times the worker thread may retry
    # before it gives up (async_max_retries), and how many requests, such as a flush or close, are
    # waiting for the worker thread to run them. Each back-off waits a second longer than the one
    # before, except while a request is waiting, which must not wait out back-offs: then the worker
    # thread does not wait at all, and submitting a request ends the back-off under way.
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
      end

      # Start counting afresh, once writing succeeds.
      def reset
        @retry_count = 0
      end

      # Start afresh for a worker thread new to the process, after a fork: it has not failed yet, and
      # the requests counted as waiting were on the queue of the parent process, which the child
      # replaces.
      def restart
        reset
        @requests.clear
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

      # Waits retry_count seconds, unless a request is waiting, or until one is submitted.
      #
      # The interruptions from before are cleared before it checks for a waiting request, so that a
      # request submitted in between either is seen waiting or interrupts the wait.
      def wait
        @interrupts.clear
        @interrupts.pop(timeout: retry_count) unless requests_waiting?
      end

      # Called before a request is added to the queue: it is waiting until #request_done, and ends the
      # back-off under way. Never waits, since an interruption already queued ends it as well.
      def request_submitted
        @requests << true
        @interrupts.push(true, timeout: 0)
      end

      # Called once for each request submitted, once it has run or will not (see Request#done).
      def request_done
        @requests.pop(timeout: 0)
      end

      # Whether a request is waiting for the worker thread to run it.
      def requests_waiting? = !@requests.empty?
    end
  end
end
