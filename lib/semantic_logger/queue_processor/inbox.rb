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

      # Returns [true|false] whether the queue is capped, and holds as many entries as it can.
      def full? = @capped && @queue.size >= max_queue_size

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
      # true, which it is asked as soon as the queue is found full, then every WAIT_CHECK_SECONDS, and
      # returns false once it returns false, such as once the worker thread has stopped for good,
      # since then nothing makes room. The block is not asked when the queue has room.
      def push(item, target = queue, wait:)
        return target.push(item) && true unless capped?
        return true if target.push(item, timeout: 0)

        loop do
          return false unless wait && yield
          return true if target.push(item, timeout: WAIT_CHECK_SECONDS)
        end
      end

      # Add the items, in order, without making the calling thread wait for room on a full queue,
      # while the block returns true. Once the queue is full, one new thread adds the rest, in order,
      # waiting for room while the block returns true. Once the block returns false, at once or while
      # that thread waits, the items not yet added are passed to `otherwise` instead, on that thread.
      # Returns true, without waiting. Takes no lock, so that it can be called from a signal trap.
      def push_aside(items, otherwise, &adding)
        rest = items.drop_while { |item| adding.call && push(item, wait: false) }
        return true if rest.empty?

        Thread.new { otherwise.call(rest.drop_while { |item| adding.call && push(item, wait: true, &adding) }) }
        true
      end

      # Take the entries of the given class off the queue, and return them, in order. The others are added
      # back, in order, behind any added meanwhile, without waiting for room; yields each one that a thread
      # waiting for room took the place of, so that it is not lost unseen. Takes no lock.
      def take(kind)
        entries       = Array.new(@queue.size) { @queue.pop(timeout: 0) }.compact
        taken, others = entries.partition { |entry| entry.is_a?(kind) }
        others.each { |entry| push(entry, wait: false) || (yield(entry) if block_given?) }
        taken
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
