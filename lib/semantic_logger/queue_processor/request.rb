module SemanticLogger
  class QueueProcessor
    # Internal: a command, such as :flush or :close, submitted on the queue for the worker thread
    # to run, while the submitting thread waits for the reply.
    #
    # It knows its command and how its reply gets back to the submitting thread, and makes sure
    # that the submitting thread is never left waiting on a reply that cannot come.
    class Request
      attr_reader :command

      def initialize(command)
        @command = command
        @replies = Queue.new
      end

      # Called by the worker thread: run the block for this request, then reply with true, or
      # with false when the block raised. Replies either way.
      def reply
        done = false
        yield
        done = true
      ensure
        @replies.push(done)
      end

      # Called by the worker thread: run this command on the appender, then reply. Returns false
      # once message processing must stop (:close).
      def run(appender)
        case command
        when :flush
          reply { appender.flush }
        when :close
          reply { appender.close }
          return false
        else
          reply { appender.logger.warn "Async: Appender thread: Ignoring unknown command: #{command}" }
        end
        true
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
