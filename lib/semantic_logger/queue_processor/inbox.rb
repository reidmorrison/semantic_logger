module SemanticLogger
  class QueueProcessor
    # Internal: the queue on which log messages, and requests such as a flush, wait for the worker
    # thread of a queue processor to take them off.
    #
    # It knows the queue, whether its size is capped, and the process that created it, and adds to
    # it, waiting for room on a full queue or not. After a fork, the child's copy of the queue holds
    # the entries of the parent, which the parent's worker thread writes, so the child replaces it.
    #
    # Also used in a signal trap, where Ruby allows a Queue to wait, but not a Mutex to be locked.
    class Inbox
      # How often, in seconds, a thread waiting for room on the full queue asks whether to keep
      # waiting (see #push), so that it does not wait for ever once nothing makes room.
      WAIT_CHECK_SECONDS = 1

      # Returns [Queue|SizedQueue] the queue.
      attr_reader :queue

      # Returns [Integer] the most entries the queue holds, or -1 for no limit.
      attr_reader :max_queue_size

      def initialize(max_queue_size)
        @max_queue_size = max_queue_size
        create
      end

      # Returns [true|false] whether the queue has a capped size.
      def capped? = @capped

      # Whether this is a child of the process that created the queue, whose copy of the queue then
      # holds that process's entries.
      def forked? = @pid != ::Process.pid

      # Closes the queue, and creates an empty one, which belongs to this process.
      def recreate
        @queue.close
        create
      end

      # Add to the `target` queue, the current one by default. Returns whether it was added.
      #
      # A queue that is not capped is never full, and its #push takes no timeout. On a full queue,
      # without `wait`, returns false at once. With `wait`, waits for room while the block returns
      # true, which it is asked every WAIT_CHECK_SECONDS, and returns false once it returns false,
      # such as once the worker thread has stopped for good, since then nothing makes room.
      def push(item, target = queue, wait:)
        return target.push(item) && true unless capped?

        loop do
          return true if target.push(item, timeout: wait ? WAIT_CHECK_SECONDS : 0)
          return false unless wait && yield
        end
      end

      # Add the item without making the calling thread wait for room on a full queue, while the block
      # returns true. When the queue is full, a new thread adds it, waiting for room while the block
      # returns true. When the block returns false, at once or while that thread waits, the item is
      # not added, and `otherwise` is called instead, on a new thread. Takes no lock, so that it can be
      # called from a signal trap.
      def push_aside(item, otherwise, &adding)
        return if adding.call && push(item, wait: false)

        Thread.new { otherwise.call unless adding.call && push(item, wait: true, &adding) }
      end

      private

      def create
        @pid = ::Process.pid
        if max_queue_size == -1
          @queue  = Queue.new
          @capped = false
        else
          @queue  = SizedQueue.new(max_queue_size)
          @capped = true
        end
      end
    end
  end
end
