module SemanticLogger
  class QueueProcessor
    # Internal: a command, such as :flush or :close, submitted on the queue for the worker thread
    # to run, while the submitting thread waits for the reply. Or a task, a Proc, handed over for the
    # worker thread to run without waiting for it (see QueueProcessor#hand_over), which nobody waits on.
    #
    # It knows its command, whether it has run, and how its reply gets back to the submitting
    # thread, and makes sure that the submitting thread is never left waiting on a reply that cannot
    # come. It also tells whoever counts the requests waiting, once, when it is no longer waiting.
    class Request
      attr_reader :command

      # The block, if any, is called once the request is no longer waiting (see #done).
      def initialize(command, &on_done)
        @command = command
        @replies = Queue.new
        @on_done = on_done
        @ran     = false
        # A single token, which the first call to #done takes.
        @waiting = Queue.new
        @waiting << true
      end

      # Whether the worker thread has run this request (see #reply).
      def ran? = @ran

      # Called once the request has run, or will not: one that could not be added to the queue, or
      # that the worker thread took off the queue but skipped, such as one behind a close. Calls the
      # block given to #initialize the first time only, whichever thread calls it, so that the request
      # is counted out once. Also called in a signal trap, where Ruby allows a Queue to be used, but
      # not a Mutex to be locked.
      def done
        @on_done&.call if @waiting.pop(timeout: 0)
      end

      # Called by the worker thread: run the block for this request, then reply with true, or
      # with false when the block raised. Replies either way.
      def reply
        succeeded = false
        yield
        succeeded = true
      ensure
        @ran = true
        done
        @replies.push(succeeded)
      end

      # Called by the worker thread: run this command on the appender, or this task, then reply.
      # Returns false once message processing must stop (:close). A command it does not know is
      # yielded to the block, for the caller to report, and otherwise ignored.
      def run(appender)
        case command
        when Proc
          reply { command.call }
        when :flush
          reply { appender.flush }
        when :close
          reply { appender.close }
          return false
        else
          reply { yield(command) if block_given? }
        end
        true
      end

      # Called once no worker thread will run this request, such as one passed on to the next worker
      # thread when none is running (see QueueProcessor#pass_on). A task runs on a new thread, since
      # nothing then writes to the appender, and returns that thread. A command is not run:
      # it replies false, so that the submitting thread does not wait for it.
      def abandon
        # A handed-over task runs on a thread of its own, so that one that raises, even SystemStackError,
        # never keeps the requests released with it from being released.
        return Thread.new(&command) if command.is_a?(Proc)

        done
        @replies.push(false)
      end

      # Called by the submitting thread: wait for the reply from the worker thread.
      #
      # The block returns whether a worker thread that can still reply is running. Returns the
      # reply, or false once none is, for example once the worker gave up after
      # async_max_retries, or was replaced after a fork.
      def wait
        loop do
          reply = @replies.pop(timeout: 1)
          return reply unless reply.nil?
          return @replies.pop(timeout: 0) || false unless yield
        end
      end
    end
  end
end
