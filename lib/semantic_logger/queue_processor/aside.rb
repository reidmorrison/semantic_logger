module SemanticLogger
  class QueueProcessor
    # Internal: the log messages logged aside (see QueueProcessor#log_aside), which are added to the
    # queue without making the calling thread wait for room, or, while the worker thread of the queue
    # processor flushes its appender, set aside for the worker thread to write, and flush, before the
    # flush returns, such as those that an appender logs as it is flushed.
    #
    # It knows the messages set aside, whether a flush is under way, whether a thread is releasing the
    # messages set aside to the queue, the process it belongs to, the Inbox it adds messages to, how to
    # write a message, what to do with a message that cannot be added, and how to tell that the thread
    # must write no more. Takes no lock, so that it can be used from a signal trap: it uses only Queues.
    class Aside
      # The most times that a flush flushes the appender again, after writing the messages logged aside
      # while it flushed. Any logged aside after that are added to the queue.
      FLUSHES = 3

      # Parameters:
      #   inbox: [Inbox]
      #     The queue the messages are added to.
      #   dropped: [#call]
      #     Called for each message that cannot be added, once the block returns false.
      #   writing: [#call]
      #     Returns whether the thread that flushes can write more, false once its stack overflowed.
      #   write: [#call]
      #     Writes a message, while a flush is under way (see #flush). What it raises is ignored, since
      #     it counts a message that it fails to write.
      #   adding:
      #     The block returns whether a message can still be added, waiting for room (see
      #     Inbox#push_aside).
      def initialize(inbox, dropped, writing, write, &adding)
        @inbox     = inbox
        @dropped   = dropped
        @writing   = writing
        @write     = write
        @adding    = adding
        @logs      = Thread::Queue.new
        @releasing = Thread::SizedQueue.new(1)
        @flushing  = false
        @pid       = ::Process.pid
      end

      # Sets the messages aside while a flush is under way, otherwise adds them, in order, to the queue,
      # without waiting for room: once it is full, one new thread adds the rest (see Inbox#push_aside).
      # When the flush ended as they were set aside, adds them to the queue all the same, so that none
      # is left aside (see #release). They are set aside together, so that they are taken off together,
      # in order. Returns true.
      #
      # In a forked child, first forgets the messages that the parent set aside, which the parent
      # writes, and its flush.
      def log(logs)
        renew_after_fork unless @pid == ::Process.pid
        return add(logs) unless @flushing

        @logs << logs
        release unless @flushing
        true
      end

      # Runs the block, which flushes the appender, and returns its result. While messages were logged
      # aside meanwhile, writes each one in turn (see #initialize), then runs the block again, up to
      # FLUSHES times. Once the thread can write no more, those left are added to the queue, for the
      # next worker thread. Any message set aside once it is done is added to the queue.
      #
      # In a forked child, first forgets the messages that the parent set aside, as #log does.
      def flush
        renew_after_fork unless @pid == ::Process.pid
        @flushing = true
        flushed   = yield
        FLUSHES.times do
          logs = take
          break if logs.empty? || !write_all(logs)

          flushed = yield
        end
        flushed
      ensure
        @flushing = false
        release
      end

      private

      # Writes each message, in order. Returns false once the thread can write no more, after adding
      # the messages left to the queue.
      def write_all(logs)
        until logs.empty?
          begin
            @write.call(logs.shift)
          rescue StandardError
            nil
          end
          next if @writing.call

          add(logs) unless logs.empty?
          return false
        end
        true
      end

      # Adds the messages to the queue, without waiting for room. Returns true.
      def add(logs) = @inbox.push_aside(logs, ->(rest) { rest.each { @dropped.call } }, &@adding)

      # Adds the messages set aside, if any, to the queue. Only one thread releases them at a time: the
      # end of a flush, or a #log that found the flush ended as it set them aside. Another thread that
      # finds one releasing leaves its messages to it, so that they are added in the order they were
      # set aside, never taken off by two threads at once: the one releasing looks again once it is
      # done, and releases those too. Takes no lock: the release is held as the one slot of a
      # SizedQueue, which is never waited for.
      def release
        loop do
          return unless @releasing.push(true, timeout: 0)

          begin
            logs = take
            add(logs) unless logs.empty?
          ensure
            @releasing.pop(timeout: 0)
          end
          return if @logs.empty?
        end
      end

      # Returns [Array<Log>] the messages set aside, taken off, in order.
      def take
        logs = []
        while (set = @logs.pop(timeout: 0))
          logs.concat(set)
        end
        logs
      end

      # Forgets, in a forked child, the messages set aside in the parent, and the parent's flush. Takes
      # no lock, so that it can be called in a signal trap.
      def renew_after_fork
        @logs      = Thread::Queue.new
        @releasing = Thread::SizedQueue.new(1)
        @flushing  = false
        @pid       = ::Process.pid
      end
    end
  end
end
