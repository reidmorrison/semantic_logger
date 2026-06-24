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
                  :batch_size, :batch_seconds
    attr_reader :appender, :queue, :max_queue_size, :non_blocking, :signal,
                :processed_count, :dropped_count

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
    #     at most once every this number of seconds.
    #     Default: 30
    def initialize(appender:,
                   max_queue_size: 10_000,
                   lag_check_interval: 1_000,
                   lag_threshold_s: 30,
                   batch: false,
                   batch_size: 300,
                   batch_seconds: 5,
                   non_blocking: false,
                   dropped_message_report_seconds: 30)
      @appender                       = appender
      @max_queue_size                 = max_queue_size
      @lag_check_interval             = lag_check_interval
      @lag_threshold_s                = lag_threshold_s
      @batch                          = batch
      @batch_size                     = batch_size
      @batch_seconds                  = batch_seconds
      @non_blocking                   = non_blocking
      @dropped_message_report_seconds = dropped_message_report_seconds
      @thread                         = nil
      @signal                         = Concurrent::Event.new
      @dropped_message_count          = 0
      @dropped_message_reported_at    = Time.now
      @dropped_message_mutex          = Mutex.new
      @processed_count                = 0
      @dropped_count                  = 0
      create_queue

      return unless batch? && !appender.respond_to?(:batch)

      raise(ArgumentError, "#{appender.class.name} does not support batching. It must implement #batch")
    end

    # Internal logger used to report problems encountered while processing log messages.
    def logger
      appender.logger
    end

    # Returns [Thread] the worker thread.
    #
    # Starts the worker thread if it is not currently running.
    def thread
      return @thread if @thread&.alive?

      @thread = Thread.new { process }
    end

    # Returns [true|false] whether the worker thread is running.
    def active?
      @thread&.alive?
    end

    # Returns [true|false] whether the queue has a capped size.
    def capped?
      @capped
    end

    # Returns [true|false] whether messages are dropped instead of blocking when the queue is full.
    # Only a capped queue can drop messages.
    def non_blocking?
      @non_blocking && capped?
    end

    # Returns [true|false] whether messages are processed in batches.
    def batch?
      @batch
    end

    # Add a log message to the queue for processing.
    #
    # When non-blocking and the queue is full, the message is dropped instead of blocking the
    # calling thread, and the count of dropped messages is reported periodically.
    def log(log)
      if non_blocking?
        begin
          queue.push(log, true)
        rescue ThreadError
          message_dropped
          return false
        end
      else
        queue << log
      end

      # For batches wake up the processing thread once the number of queued messages has been exceeded.
      signal.set if batch? && (queue.size >= batch_size)

      true
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
    def reopen
      # Workaround CRuby crash on fork by recreating queue on reopen
      #   https://github.com/reidmorrison/semantic_logger/issues/103
      @queue&.close
      create_queue

      @thread&.kill if @thread&.alive?
      @thread = Thread.new { process }
    end

    private

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
    def process
      # This thread is designed to never go down unless the main thread terminates
      # or the appender is closed.
      Thread.current.name = logger.name
      logger.trace "Async: Appender thread active"
      begin
        batch? ? process_messages_in_batches : process_messages
      rescue StandardError => e
        safe_log(:error, "Async: Restarting due to exception", e)
        retry
      rescue Exception => e
        safe_log(:error, "Async: Stopping due to fatal exception", e)
      ensure
        @thread = nil
        safe_log(:trace, "Async: Thread has stopped")
      end
    end

    # Log to the internal logger, ignoring any error.
    # These calls may run after Ruby has released file handles during shutdown.
    def safe_log(level, message, exception = nil)
      logger.public_send(level, message, exception)
    rescue StandardError
      nil
    end

    # Streaming: write each log message to the appender as it is dequeued.
    def process_messages
      count = 0
      while (message = queue.pop)
        if message.is_a?(Log)
          appender.log(message)
          @processed_count += 1
          count += 1
          # Check every few log messages whether this appender thread is falling behind
          if count > lag_check_interval
            check_lag(message)
            count = 0
          end
        else
          break unless process_message(message)
        end
      end
      logger.trace "Async: Queue Closed"
    end

    # Batching: group up log messages before writing them via the appender's #batch method.
    def process_messages_in_batches
      loop do
        # Wait for batch interval or number of messages to be exceeded.
        signal.wait(batch_seconds)

        logs          = []
        messages      = []
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
            messages << message
          end
        end
        if logs.size.positive?
          appender.batch(logs)
          @processed_count += logs.size
        end
        messages.each { |message| process_message(message) }
        signal.reset unless queue.size >= batch_size
      end
    end

    # Returns false when message processing should be stopped.
    def process_message(message)
      case message[:command]
      when :flush
        appender.flush
        message[:reply_queue] << true if message[:reply_queue]
      when :close
        appender.close
        message[:reply_queue] << true if message[:reply_queue]
        return false
      else
        logger.warn "Async: Appender thread: Ignoring unknown command: #{message[:command]}"
      end
      true
    end

    # Record a dropped message, reporting the running count to the internal logger at most
    # once every dropped_message_report_seconds.
    def message_dropped
      @dropped_message_mutex.synchronize do
        @dropped_message_count += 1
        @dropped_count         += 1
        diff = Time.now - @dropped_message_reported_at
        return if diff < dropped_message_report_seconds

        logger.warn(
          "Async: Dropped #{@dropped_message_count} log messages in the last #{diff.round} seconds. " \
          "The queue is full (max_queue_size: #{max_queue_size}). " \
          "Consider reducing the log level, increasing max_queue_size, or changing the appenders"
        )
        @dropped_message_count       = 0
        @dropped_message_reported_at = Time.now
      end
    end

    def check_lag(log)
      diff = Time.now - log.time
      return unless diff > lag_threshold_s

      logger.warn "Async: Appender thread has fallen behind by #{diff} seconds with #{queue.size} messages queued up. Consider reducing the log level or changing the appenders"
    end

    # Submit a command to the worker thread and wait for the reply.
    def submit_request(command)
      return false unless active?

      queue_size = queue.size
      msg        = "Async: Queued log messages: #{queue_size}, running command: #{command}"
      if queue_size > 1_000
        logger.warn msg
      elsif queue_size > 100
        logger.info msg
      elsif queue_size.positive?
        logger.trace msg
      end

      # Wake up the processing thread to process this command immediately.
      signal.set if batch?

      reply_queue = Queue.new
      queue << {command: command, reply_queue: reply_queue}
      reply_queue.pop
    end
  end
end
