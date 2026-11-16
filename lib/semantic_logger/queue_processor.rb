require "semantic_logger/queue_processor/request"
require "semantic_logger/queue_processor/throttled_counter"
require "semantic_logger/queue_processor/reporter"

module SemanticLogger
  # Internal class that processes log messages from a queue on a separate thread.
  #
  # Internal use only: it owns the worker thread and the in-memory queue that back the
  # asynchronous appender proxy (SemanticLogger::Appender::Async). It is never returned to
  # application code.
  #
  # Supports two processing modes, selected by the `batch:` option:
  #   * Streaming (batch: false): each log message is written to the appender as it is dequeued.
  #   * Batching  (batch: true):  log messages are grouped and written via the appender's #batch
  #                               method, either once batch_size messages have accumulated, or
  #                               batch_seconds have elapsed since the previous batch.
  class QueueProcessor
    attr_accessor :lag_check_interval, :lag_threshold_s, :dropped_message_report_seconds,
                  :batch_size, :batch_seconds, :non_blocking
    attr_reader :appender, :queue, :max_queue_size, :signal,
                :processed_count, :async_max_retries, :retry_count

    # Create a new processor and start its worker thread.
    def self.start(**args)
      processor = new(**args)
      processor.thread
      processor
    end

    # Parameters:
    #   appender: [SemanticLogger::Subscriber]
    #     The appender to forward log messages to from the worker thread.
    #
    #   max_queue_size: [Integer]
    #     The maximum number of log messages to hold on the queue before blocking attempts to add to the queue.
    #     -1: The queue size is uncapped and will never block no matter how long the queue is.
    #     Default: 10,000
    #
    #   lag_threshold_s: [Float]
    #     Log a warning when a log message has been on the queue for longer than this period in seconds.
    #     Default: 30
    #
    #   lag_check_interval: [Integer]
    #     Number of messages to process before checking for slow logging.
    #     Default: 1,000
    #     Note: Not applicable when batch: true.
    #
    #   batch: [true|false]
    #     Process log messages in batches via the appender's #batch method.
    #     Default: false
    #     Note: The appender must implement #batch.
    #
    #   batch_size: [Integer]
    #     Maximum number of messages to batch up before sending.
    #     Default: 300
    #     Note: Only applicable when batch: true.
    #
    #   batch_seconds: [Integer]
    #     Maximum number of seconds between sending batches.
    #     Default: 5
    #     Note: Only applicable when batch: true.
    #
    #   non_blocking: [true|false]
    #     Whether to drop log messages instead of blocking the calling thread when the queue is full.
    #     Only applies to a capped queue.
    #     Default: false
    #
    #   dropped_message_report_seconds: [Integer]
    #     When non_blocking is enabled, log the count of dropped messages to the internal logger
    #     at most once every this number of seconds. Also limits how often messages discarded
    #     because they could not be written are reported, after the first.
    #     Default: 30
    #
    #   async_max_retries: [Integer]
    #     Maximum number of consecutive times to restart the worker thread after it raises an
    #     exception while processing messages. Each restart first sleeps for `retry_count` seconds
    #     (1s, then 2s, ...) as a back-off. Once this many consecutive retries are exhausted the
    #     thread stops instead of restarting. The counter resets to zero whenever a message is
    #     processed successfully.
    #     -1: Retry indefinitely and never stop the thread (the pre-v5 behaviour). The back-off
    #         still applies, and still resets after any successful message.
    #     Default: 100
    def initialize(appender:,
                   max_queue_size: 10_000,
                   lag_check_interval: 1_000,
                   lag_threshold_s: 30,
                   batch: false,
                   batch_size: 300,
                   batch_seconds: 5,
                   non_blocking: false,
                   dropped_message_report_seconds: 30,
                   async_max_retries: 100)
      @appender                       = appender
      @max_queue_size                 = max_queue_size
      @lag_check_interval             = lag_check_interval
      @lag_threshold_s                = lag_threshold_s
      @batch                          = batch
      @batch_size                     = batch_size
      @batch_seconds                  = batch_seconds
      @non_blocking                   = non_blocking
      @dropped_message_report_seconds = dropped_message_report_seconds
      @async_max_retries              = async_max_retries
      @retry_count                    = 0
      @thread                         = nil
      # Only batch mode parks the worker on the signal; streaming mode never touches it.
      @signal                         = Concurrent::Event.new if batch
      @reporter                       = Reporter.new(appender)
      @processed_count                = 0
      create_queue

      return unless batch? && !appender.respond_to?(:batch)

      raise(ArgumentError, "#{appender.class.name} does not support batching. It must implement #batch")
    end

    # Internal logger used to report problems encountered while processing log messages.
    def logger = @reporter.logger

    # Returns [Thread] the worker thread.
    #
    # Starts the worker thread if it is not currently running.
    def thread
      return @thread if @thread&.alive?

      @thread = spawn_worker
    end

    # Returns [true|false] whether the worker thread is running.
    def active? = @thread&.alive?

    # Returns [true|false] whether the queue has a capped size.
    def capped? = @capped

    # Returns [true|false] whether messages are dropped instead of blocking when the queue is full.
    # Only a capped queue can drop messages.
    def non_blocking? = @non_blocking && capped?

    # Returns [Integer] the number of log messages dropped because the queue was full.
    def dropped_count = @reporter.dropped_count

    # Returns [Integer] the number of log messages discarded because they could not be written,
    # whether their content or the destination was at fault (see Subscriber#message_error?).
    def failed_count = @reporter.failed_count

    # Returns [true|false] whether messages are processed in batches.
    def batch? = @batch

    # Returns [true|false] whether the worker thread gave up after an error, so that queued
    # messages are no longer being processed.
    def stopped? = @stopped == true

    # Add a log message to the queue for processing.
    #
    # When non-blocking and the queue is full, the message is dropped instead of blocking the
    # calling thread, and the count of dropped messages is reported periodically.
    #
    # Once the worker thread has stopped for good (see async_max_retries), nothing will empty the
    # queue, so messages are also dropped instead of blocking the calling thread forever.
    def log(log)
      enqueued = true
      if non_blocking? || stopped?
        begin
          queue.push(log, true)
        rescue ThreadError
          message_dropped
          enqueued = false
        end
      else
        queue << log
      end

      # For batches wake up the processing thread once the number of queued messages has been
      # exceeded. Also wake it on a drop so it drains the full queue rather than waiting out the
      # batch interval.
      signal.set if batch? && (queue.size >= batch_size)

      enqueued
    end

    # Flush all queued log entries to the appender.
    #  All queued log messages are written and then the appender is flushed.
    def flush
      submit_request(:flush)
    end

    # Flush any outstanding messages and close the appender.
    def close
      submit_request(:close)
    end

    # Re-open the queue and worker thread after a fork.
    #
    # Also called from a signal trap, such as one that reopens the log files after a rotation, where
    # Ruby does not allow a Mutex to be locked, so it takes none.
    def reopen
      # Workaround CRuby crash on fork by recreating queue on reopen
      #   https://github.com/reidmorrison/semantic_logger/issues/103
      @queue&.close
      create_queue

      @thread&.kill if @thread&.alive?
      @thread = spawn_worker
    end

    private

    # Start the worker thread.
    def spawn_worker
      @stopped        = false
      @stack_overflow = nil
      Thread.new do
        name_worker
        process
      end
    end

    # Name the worker thread after its appender, such as "SL File", short enough for tools that
    # list threads, such as `top -H`, to tell the workers apart: Linux keeps only the first 15 bytes.
    # The name is only a label, so when Ruby rejects it, for example for a class given a temporary
    # name with a NUL byte, the thread carries on without one.
    def name_worker
      Thread.current.name = ["SL", appender.class.name&.split("::")&.last].compact.join(" ")
    rescue StandardError
      nil
    end

    def create_queue
      if max_queue_size == -1
        @queue  = Queue.new
        @capped = false
      else
        @queue  = SizedQueue.new(max_queue_size)
        @capped = true
      end
    end

    # Separate thread for processing log messages.
    #
    # This thread is designed to never go down unless the main thread terminates or the appender is
    # closed. A StandardError while processing restarts the processing, after a back-off, up to
    # async_max_retries times. Any other exception, even one from the first report, stops this
    # processor, which then drops new messages, rather than ending the thread and leaving the
    # calling threads blocked on a full queue.
    def process
      safe_log(:trace, "Async: Appender thread active")
      begin
        carry_on = batch? ? process_messages_in_batches : process_messages
      rescue StandardError => e
        if async_max_retries == -1 || retry_count < async_max_retries
          @retry_count += 1
          limit = async_max_retries == -1 ? "unlimited" : async_max_retries
          safe_log(:warn,
                   "Async: Restarting due to exception, retry #{retry_count} of #{limit}, sleeping #{retry_count}s", e)
          sleep(retry_count)
          retry
        else
          @stopped = true
          safe_log(:error, "Async: Stopping after #{retry_count} failed retries, dropping new messages", e)
        end
      end
    rescue Exception => e
      @stopped = true
      safe_log(:error, "Async: Stopping due to fatal exception", e)
    ensure
      # A thread that overflowed its stack hands the queue over to a new one (see #stack_overflowed),
      # unless #reopen has already replaced it. Any other thread leaves @thread as it is, since one
      # that has ended reads as inactive, and #reopen may already have replaced it with a new one.
      @thread = spawn_worker if carry_on && @thread.equal?(Thread.current)
      safe_log(:trace, "Async: Thread has stopped") unless carry_on
    end

    # Report to the internal logger, ignoring any error (see Reporter#log).
    def safe_log(level, message, exception = nil) = @reporter.log(level, message, exception)

    # Streaming: write each log message to the appender as it is dequeued.
    #
    # Returns true when processing must carry on in a new thread (see #stack_overflowed).
    def process_messages
      count = 0
      while (message = queue.pop)
        if message.is_a?(Log)
          write_message(message)
          return true if @stack_overflow

          @retry_count = 0 unless retry_count.zero?
          count += 1
          # Check every few log messages whether this appender thread is falling behind
          if count > lag_check_interval
            check_lag(message)
            count = 0
          end
        else
          break unless run_command(message)
        end
      end
      safe_log(:trace, "Async: Queue Closed")
      false
    end

    # Batching: group up log messages before writing them via the appender's #batch method.
    #
    # Returns true when processing must carry on in a new thread (see #stack_overflowed).
    def process_messages_in_batches
      loop do
        # Wait for batch interval or number of messages to be exceeded.
        signal.wait(batch_seconds)

        logs          = []
        commands      = []
        first         = true
        message_count = queue.length
        message_count.times do
          # Queue#pop(true) raises an exception when there are no more messages, which is considered expensive.
          message = queue.pop
          if message.is_a?(Log)
            logs << message
            if first
              check_lag(message)
              first = false
            end
          else
            commands << message
          end
        end
        # Stop processing once a command (e.g. :close) signals the thread to terminate.
        return false unless write_batch_then_run(logs, commands)
        return true if @stack_overflow

        signal.reset unless queue.size >= batch_size
      end
    end

    # Write the log messages taken off the queue as a batch, then run the commands taken off the
    # queue with them. Returns false once a command (:close) stops processing.
    #
    # When the batch cannot be written, for example because the destination is unavailable, the
    # messages not yet written are discarded and counted as failed, since #process starts again
    # from the queue. The commands still run before the error propagates to #process to back off.
    # Otherwise they would be lost, and a caller waiting on #flush or #close, such as the flush at
    # exit, would wait forever.
    def write_batch_then_run(logs, commands)
      accounted = processed_count + failed_count
      unless logs.empty?
        write_batch(logs)
        @retry_count = 0 unless retry_count.zero?
      end
      commands.all? { |command| run_command(command) }
    rescue StandardError => e
      # Every message taken off the queue was written or already discarded, except those still
      # to be written when the error was raised: the last ones, since a batch is written in order.
      unwritten = logs.size - (processed_count + failed_count - accounted)
      messages_failed(logs.last(unwritten), e) if unwritten.positive?
      raise e if commands.all? { |command| process_message_after_failure(command) }

      safe_log(:warn, "Async: Closed without writing #{unwritten} log messages", e)
      false
    end

    # Run a command after a batch could not be written. Returns false once a command (:close)
    # stops processing, even when the command itself fails.
    def process_message_after_failure(command)
      run_command(command)
    rescue StandardError => e
      safe_log(:warn, "Async: Failed to #{command.command} the appender", e)
      command.command != :close
    end

    # Run a command taken off the queue on the appender, reporting one it does not know. Returns
    # false once message processing must stop (:close).
    def run_command(request)
      request.run(appender) do |command|
        safe_log(:warn, "Async: Appender thread: Ignoring unknown command: #{command}")
      end
    end

    # Write one log message to the appender.
    #
    # A message that cannot be written is discarded and reported. When its content is at fault
    # (see #message_error?) the thread carries on with the next message. Any other error, such as
    # the destination being unavailable, then propagates to #process, which backs off before
    # carrying on with the next message. A stack overflow discards the message too (see
    # #stack_overflowed).
    def write_message(log)
      appender.log(log)
      @processed_count += 1
    rescue SystemStackError => e
      stack_overflowed([log], e)
    rescue StandardError => e
      messages_failed([log], e)
      raise e unless message_error?(e)
    end

    # Write the log messages to the appender as a batch.
    #
    # When the content of a message cannot be written (see #message_error?), and the appender's
    # #batch is all or nothing, the batch is split in half and each half written separately, so
    # that only the offending message is discarded rather than every message in the batch.
    # Otherwise the batch is discarded, since writing it again could duplicate the messages that
    # the appender had already written. A stack overflow discards the batch, and the rest of the
    # batch being split, without splitting it further (see #stack_overflowed).
    def write_batch(logs)
      return messages_failed(logs, @stack_overflow) if @stack_overflow

      appender.batch(logs)
      @processed_count += logs.size
    rescue SystemStackError => e
      stack_overflowed(logs, e)
    rescue StandardError => e
      raise unless message_error?(e)
      return messages_failed(logs, e) if logs.size == 1 || !appender.batch_all_or_nothing?

      logs.each_slice((logs.size + 1) / 2) { |half| write_batch(half) }
    end

    # Discard log messages whose writing overflowed the stack, for example a value nested too
    # deeply for a custom formatter. Retrying cannot write them, as for #message_error?.
    #
    # This thread must not overflow its stack again: on macOS a second stack overflow on the same
    # thread crashes Ruby. So nothing else is written on it, including the rest of a batch, which
    # is discarded rather than split up further to find the message at fault. Once any commands
    # taken off the queue with the messages have run, a new thread carries on (see #process).
    def stack_overflowed(logs, exception)
      @stack_overflow = exception
      messages_failed(logs, exception)
    end

    # Whether the appender says the exception was caused by the content of a log message, rather
    # than by the destination. An appender that cannot tell (it does not implement
    # #message_error?) has every error treated as the destination's, so the thread backs off.
    def message_error?(exception) = appender.respond_to?(:message_error?) && appender.message_error?(exception)

    # Record log messages discarded because they could not be written, whether their content or
    # the destination was at fault, reported at most once every dropped_message_report_seconds
    # after the first (see Reporter#failed).
    def messages_failed(logs, exception)
      @reporter.failed(logs, exception, interval: dropped_message_report_seconds)
    end

    # Record a dropped message, reported at most once every dropped_message_report_seconds.
    def message_dropped = @reporter.dropped(max_queue_size, interval: dropped_message_report_seconds)

    def check_lag(log)
      diff = Time.now - log.time
      return unless diff > lag_threshold_s

      safe_log(:warn, "Async: Appender thread has fallen behind by #{diff} seconds with " \
                      "#{queue.size} messages queued up. Consider reducing the log level or " \
                      "changing the appenders")
    end

    # Submit a command to the worker thread and wait for the reply.
    def submit_request(command)
      return false unless active?

      queue_size = queue.size
      msg        = "Async: Queued log messages: #{queue_size}, running command: #{command}"
      if queue_size > 1_000
        safe_log(:warn, msg)
      elsif queue_size > 100
        safe_log(:info, msg)
      elsif queue_size.positive?
        safe_log(:trace, msg)
      end

      # Wake up the processing thread to process this command immediately.
      signal.set if batch?

      submitted_to = queue
      request      = Request.new(command)
      submitted_to << request
      # A reply can come while the request is on the current queue, which #reopen replaces, and a
      # worker thread is running it, which may be a new one after a stack overflow.
      request.wait { queue.equal?(submitted_to) && active? }
    end
  end
end
