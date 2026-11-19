module SemanticLogger
  class QueueProcessor
    # Internal: what became of a batch of log messages whose write raised a message error (see
    # Subscriber#message_error?), as the appender tells from the error, for the worker thread of a
    # queue processor to carry on with: how many of them the destination stored, those to discard,
    # and the parts of the batch to write again.
    #
    # When the appender says which message the destination rejected, having stored those before it
    # (see Subscriber#rejected_entry), those before it were written, it is discarded, and those after
    # it are written again as a batch. Otherwise, when the appender's #batch is all or nothing (see
    # Subscriber#batch_all_or_nothing?), the batch is split in half, and each half written again, so
    # that only the messages at fault are discarded, unless the error would fail any batch (see
    # Subscriber#fails_any_batch?). Any other batch is discarded, since writing it again could write
    # some of its messages twice.
    class BatchFailure
      # Returns [Integer] how many of the messages, from the first, the destination stored.
      attr_reader :written

      # Returns [Array<Log>] the messages to discard.
      attr_reader :discarded

      # Returns [Array<Array<Log>>] the parts of the batch to write again, in order.
      attr_reader :parts

      def initialize(appender, logs, exception)
        @appender  = appender
        @exception = exception
        @written   = 0
        @discarded = []
        @parts     = []
        rejected   = rejected_entry(logs)
        if rejected
          after_rejected(logs, rejected)
        elsif logs.size == 1 || !appender.batch_all_or_nothing? || fails_any_batch?
          @discarded = logs
        else
          @parts = logs.each_slice((logs.size + 1) / 2).to_a
        end
      end

      private

      attr_reader :appender, :exception

      # The destination stored the messages before the one at position `rejected`, and rejected that
      # one, along with every one after it when the error would fail any batch.
      def after_rejected(logs, rejected)
        @written   = rejected
        @discarded = fails_any_batch? ? logs.drop(rejected) : [logs[rejected]]
        rest       = logs.drop(rejected + @discarded.size)
        @parts     = [rest] unless rest.empty?
      end

      # Returns [Integer|nil] the position in the batch of the message that the destination
      # rejected, when the appender says so, or nil when it does not, or names no message in the
      # batch. An appender that does not implement #rejected_entry cannot say.
      def rejected_entry(logs)
        rejected = appender.respond_to?(:rejected_entry) && appender.rejected_entry(exception)
        rejected if rejected.is_a?(Integer) && rejected.between?(0, logs.size - 1)
      end

      # An appender that does not implement #fails_any_batch? has every all or nothing batch split,
      # as before it could say.
      def fails_any_batch?
        appender.respond_to?(:fails_any_batch?) && appender.fails_any_batch?(exception)
      end
    end
  end
end
