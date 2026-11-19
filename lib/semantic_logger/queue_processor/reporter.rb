module SemanticLogger
  class QueueProcessor
    # Internal: reports what happens on the worker thread of a queue processor, its progress and its
    # problems, to the internal logger of its appender.
    #
    # It knows that logger, which is the appender's to choose, and makes sure that a report neither
    # stops the worker thread nor raises into a calling thread, whatever the logger. It counts the log
    # messages dropped because the queue was full, and those discarded because they could not be
    # written, and reports each count at most once per interval.
    class Reporter
      # The kinds of positional parameter that Method#parameters reports, other than *rest.
      POSITIONAL = %i[req opt].freeze
      private_constant :POSITIONAL

      def initialize(appender)
        @appender = appender
        @dropped  = ThrottledCounter.new
        @failed   = ThrottledCounter.new(reported_at: nil)
      end

      # Returns the internal logger of the appender, which it can replace at any time.
      def logger = @appender.logger

      # Returns [Integer] the number of log messages dropped because the queue was full.
      def dropped_count = @dropped.total

      # Returns [Integer] the number of log messages discarded because they could not be written,
      # whether their content or the destination was at fault (see Subscriber#message_error?).
      def failed_count = @failed.total

      # Log to the internal logger, ignoring any StandardError. These calls may run after Ruby has
      # released file handles during shutdown, and the internal logger may not take them, such as a
      # Ruby Logger, which has no #trace, returned by a custom appender's own #logger.
      #
      # Such a logger also takes only the message. So the exception is passed only when there is one,
      # and is added to the message instead for a logger that does not take it (see #takes_exception?).
      def log(level, message, exception = nil)
        internal = logger
        return internal.public_send(level, message) unless exception
        return internal.public_send(level, message, exception) if takes_exception?(internal, level)

        internal.public_send(
          level,
          Utils.join_texts(message, " -- ", Utils.exception_name(exception), ": ", Utils.exception_message(exception))
        )
      rescue StandardError
        nil
      end

      # Record a log message dropped because the queue was full, reporting the running count at most
      # once every `interval` seconds. The report gives the reason for the latest drop: a queue too
      # small for the volume of messages, or, when `stopped`, a worker thread that has stopped for
      # good, so that nothing empties the queue, however large.
      def dropped(max_queue_size, stopped:, interval:)
        @dropped.record(interval: interval) do |count, seconds|
          advice =
            if stopped
              "The worker thread has stopped after failing to write (see async_max_retries), so nothing " \
                "empties the queue until SemanticLogger.reopen(force: true) starts it again"
            else
              "The queue is full (max_queue_size: #{max_queue_size}). " \
                "Consider reducing the log level, increasing max_queue_size, or changing the appenders"
            end
          log(:warn, "Async: Dropped #{count} log messages in the last #{seconds.round} seconds. #{advice}")
        end
      end

      # Report that the worker thread has fallen behind, when the log message it took off the queue
      # was logged more than `threshold` seconds ago, with the number of messages still `queued`.
      def lag(entry, threshold, queued)
        diff = Time.now - entry.time
        return unless diff > threshold

        log(:warn, "Async: Appender thread has fallen behind by #{diff} seconds with #{queued} messages " \
                   "queued up. Consider reducing the log level or changing the appenders")
      end

      # Report the number of log messages queued ahead of a command, such as a flush, that is being
      # submitted: at :warn for more than 1,000, at :info for more than 100, otherwise at :trace, and
      # not at all for none.
      def queued(count, command)
        level = (count > 1_000 && :warn) || (count > 100 && :info) || (count.positive? && :trace)
        log(level, "Async: Queued log messages: #{count}, running command: #{command}") if level
      end

      # Record log messages discarded because they could not be written, whether their content or the
      # destination was at fault, if any. The first is reported straight away, with the error. After
      # that the count is reported, with the latest error, at most once every `interval` seconds.
      def failed(logs, exception, interval:)
        return if logs.empty?

        @failed.record(logs.size, interval: interval) do |count, seconds|
          period = seconds ? " in the last #{seconds.round} seconds" : ""
          log(:error, "Async: Discarded #{count} log message(s)#{period} that could not be written, " \
                      "most recently from #{logs.first.name}", exception)
        end
      end

      private

      # Whether the logger's method for the level takes the exception after the message, as a Semantic
      # Logger logger does. A Ruby or Rails Logger takes only the message: at most one positional
      # parameter, and no *rest. Decided before the call, rather than by rescuing ArgumentError, which a
      # logger that does take it can raise too, such as a broadcast logger one of whose loggers raises,
      # after the others have written the report.
      def takes_exception?(internal, level)
        parameters = internal.method(level).parameters
        parameters.any? { |type, _name| type == :rest } ||
          parameters.count { |type, _name| POSITIONAL.include?(type) } > 1
      end
    end
  end
end
