module SemanticLogger
  class QueueProcessor
    # Internal: the log messages, one or a batch, whose write the destination of the appender failed
    # without storing any of them, held for the worker thread of a queue processor to write again
    # once it has backed off, ahead of the messages on the queue.
    #
    # It knows the messages held, and how many times in a row they have been held again after the
    # destination answered the write with a failure. It holds them again after such an answer at most
    # MAX_RESENDS times, so that messages the destination fails every time, such as a request it
    # answers with a 429 that never clears, are discarded rather than hold up the messages behind
    # them until the worker thread gives up after async_max_retries. A write that never reached the
    # destination, such as one that could not connect, is not counted: the destination has said
    # nothing about these messages, so an outage loses none of them until the worker thread gives up.
    class HeldWrite
      # The most times the same messages are written again after the destination answered that it
      # failed them. A constant rather than an option: it only limits how long one write that keeps
      # failing holds up the queue, while async_max_retries already sets how long the worker thread
      # keeps trying through an outage.
      MAX_RESENDS = 3

      def initialize
        @logs    = nil
        @resends = 0
      end

      # Holds the messages to write again. `answered` says whether the destination answered the
      # write that failed, rather than never received it, which counts towards MAX_RESENDS. Returns
      # false, without holding them, when the destination answered and they have already been held
      # again MAX_RESENDS times after it did.
      def hold(logs, answered:)
        if answered
          return false if @resends >= MAX_RESENDS

          @resends += 1
        end
        @logs = logs
        true
      end

      # Yields the messages held, if any, for the block to write them again. Those the block holds
      # again keep the count; any other messages held later start afresh.
      def resend
        return unless @logs

        logs  = @logs
        @logs = nil
        yield logs
      ensure
        @resends = 0 unless @logs
      end

      # Forgets the messages held, if any, and returns them, such as when the worker thread gives up
      # on them, or after a fork, when the parent process writes them.
      def release
        logs     = @logs
        @logs    = nil
        @resends = 0
        logs
      end
    end
  end
end
