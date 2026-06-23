require "forwardable"

module SemanticLogger
  module Appender
    # Allow any appender to run asynchronously in a separate thread.
    class Async
      extend Forwardable

      attr_accessor :lag_check_interval, :lag_threshold_s, :dropped_message_report_seconds
      attr_reader :queue, :appender, :max_queue_size, :non_blocking

      # Forward methods that can be called directly
      def_delegator :@appender, :name
      def_delegator :@appender, :should_log?
      def_delegator :@appender, :filter
      def_delegator :@appender, :host
      def_delegator :@appender, :application
      def_delegator :@appender, :environment
      def_delegator :@appender, :level
      def_delegator :@appender, :level=
      def_delegator :@appender, :logger
      def_delegator :@appender, :logger=
      def_delegator :@appender, :console_stream
      def_delegator :@appender, :console_output?

      # Appender proxy to allow an existing appender to run asynchronously in a separate thread.
      #
      # Parameters:
      #   max_queue_size: [Integer]
      #     The maximum number of log messages to hold on the queue before blocking attempts to add to the queue.
      #     -1: The queue size is uncapped and will never block no matter how long the queue is.
      #     Default: 10,000
      #
      #   lag_threshold_s [Float]
      #     Log a warning when a log message has been on the queue for longer than this period in seconds.
      #     Default: 30
      #
      #   lag_check_interval: [Integer]
      #     Number of messages to process before checking for slow logging.
      #     Default: 1,000
      #
      #   non_blocking: [true|false]
      #     Whether to drop log messages instead of blocking the calling thread when the queue is full.
      #     When true and the queue is capped, attempts to add to a full queue return immediately and
      #     the message is dropped. The number of dropped messages is logged to the internal logger
      #     periodically (see dropped_message_report_seconds). Only applies to a capped queue.
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
                     non_blocking: false,
                     dropped_message_report_seconds: 30)
        @appender                       = appender
        @lag_check_interval             = lag_check_interval
        @lag_threshold_s                = lag_threshold_s
        @thread                         = nil
        @max_queue_size                 = max_queue_size
        @non_blocking                   = non_blocking
        @dropped_message_report_seconds = dropped_message_report_seconds
        @dropped_message_count          = 0
        @dropped_message_reported_at    = Time.now
        @dropped_message_mutex          = Mutex.new
        @processed_count                = 0
        @dropped_count                  = 0
        create_queue
        thread
      end

      # Re-open appender after a fork
      def reopen
        # Workaround CRuby crash on fork by recreating queue on reopen
        #   https://github.com/reidmorrison/semantic_logger/issues/103
        @queue&.close
        create_queue

        appender.reopen if appender.respond_to?(:reopen)

        @thread&.kill if @thread&.alive?
        @thread = Thread.new { process }
      end

      # Returns [true|false] if the queue has a capped size.
      def capped?
        @capped
      end

      # Returns [true|false] whether messages are dropped instead of blocking when the queue is full.
      # Only a capped queue can drop messages.
      def non_blocking?
        @non_blocking && capped?
      end

      # Returns [Thread] the worker thread.
      #
      # Starts the worker thread if not running.
      def thread
        return @thread if @thread&.alive?

        @thread = Thread.new { process }
      end

      # Returns true if the worker thread is active
      def active?
        @thread&.alive?
      end

      # Returns [Hash] operational statistics for this appender.
      #
      #   name:           [String]  Name of the wrapped appender.
      #   async:          [true]    This appender logs asynchronously via a separate thread.
      #   thread_active:  [Boolean] Whether the worker thread is currently running.
      #   queue_size:     [Integer] Number of log messages currently waiting to be written.
      #   capped:         [Boolean] Whether the queue has a maximum size.
      #   max_queue_size: [Integer] Maximum queue size, or nil when uncapped.
      #   processed:      [Integer] Cumulative number of log messages written since startup.
      #   dropped:        [Integer] Cumulative number of log messages dropped because the queue
      #                             was full (only possible when non_blocking is enabled).
      def stats
        {
          name:           name,
          async:          true,
          thread_active:  active? || false,
          queue_size:     queue.size,
          capped:         capped?,
          max_queue_size: capped? ? max_queue_size : nil,
          processed:      @processed_count,
          dropped:        @dropped_count
        }
      end

      # Add log message for processing.
      #
      # When non-blocking and the queue is full, the message is dropped instead of blocking the
      # calling thread, and the count of dropped messages is reported periodically.
      def log(log)
        if non_blocking?
          begin
            queue.push(log, true)
          rescue ThreadError
            message_dropped
          end
        else
          queue << log
        end
      end

      # Flush all queued log entries disk, database, etc.
      #  All queued log messages are written and then each appender is flushed in turn.
      def flush
        submit_request(:flush)
      end

      # Close all appenders and flush any outstanding messages.
      def close
        # TODO: Prevent new close requests once this appender has been closed.
        submit_request(:close)
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

      # Separate thread for batching up log messages before writing.
      def process
        # This thread is designed to never go down unless the main thread terminates
        # or the appender is closed.
        Thread.current.name = logger.name
        logger.trace "Async: Appender thread active"
        begin
          process_messages
        rescue StandardError => e
          # This block may be called after the file handles have been released by Ruby
          begin
            logger.error("Async: Restarting due to exception", e)
          rescue StandardError
            nil
          end
          retry
        rescue Exception => e
          # This block may be called after the file handles have been released by Ruby
          begin
            logger.error("Async: Stopping due to fatal exception", e)
          rescue StandardError
            nil
          end
        ensure
          @thread = nil
          # This block may be called after the file handles have been released by Ruby
          begin
            logger.trace("Async: Thread has stopped")
          rescue StandardError
            nil
          end
        end
      end

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

      # Returns false when message processing should be stopped
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

      # Submit command and wait for reply
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

        reply_queue = Queue.new
        queue << {command: command, reply_queue: reply_queue}
        reply_queue.pop
      end
    end
  end
end
