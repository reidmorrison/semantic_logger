require "forwardable"

module SemanticLogger
  module Appender
    # Proxy that allows any appender to run asynchronously in a separate thread.
    #
    # The worker thread and the in-memory queue are owned by an internal
    # SemanticLogger::QueueProcessor. This proxy forwards log/flush/close/reopen on to the
    # processor, and forwards the remaining appender methods (name, level, ...) directly to
    # the wrapped appender so they keep executing on the caller's thread.
    class Async
      extend Forwardable

      attr_reader :appender, :processor

      # Methods forwarded directly to the wrapped appender (run on the caller's thread).
      def_delegators :@appender,
                     :name, :should_log?, :filter, :host, :application, :environment,
                     :level, :level=, :logger, :logger=, :console_stream, :console_output?

      # Methods forwarded to the queue processor that owns the thread and queue.
      # Tuning options (max_queue_size, batch_size, non_blocking, ...) are set once at
      # construction via SemanticLogger.add_appender, so only the values that callers actually
      # read back are re-exposed here. lag_* backs the public SemanticLogger.lag_* API.
      def_delegators :@processor,
                     :log, :flush, :close, :thread, :active?, :queue, :max_queue_size,
                     :capped?, :non_blocking?, :batch?,
                     :lag_check_interval, :lag_check_interval=,
                     :lag_threshold_s, :lag_threshold_s=,
                     :processed_count, :dropped_count

      # Appender proxy to allow an existing appender to run asynchronously in a separate thread.
      #
      # Parameters:
      #   appender: [SemanticLogger::Subscriber]
      #     The appender to log to in a separate thread.
      #
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
      #     Note: Not applicable when batch: true.
      #
      #   batch: [true|false]
      #     Process log messages in batches via the appender's #batch method, instead of one at a time.
      #     The appender must implement #batch.
      #     Default: false
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
      #     When true and the queue is capped, attempts to add to a full queue return immediately and
      #     the message is dropped. The number of dropped messages is logged to the internal logger
      #     periodically (see dropped_message_report_seconds). Only applies to a capped queue.
      #     Default: false
      #
      #   dropped_message_report_seconds: [Integer]
      #     When non_blocking is enabled, log the count of dropped messages to the internal logger
      #     at most once every this number of seconds.
      #     Default: 30
      #
      #   async_max_retries: [Integer]
      #     Maximum number of consecutive times to restart the worker thread (with a back-off)
      #     after it raises an exception while processing messages, before giving up and stopping
      #     the thread. The counter resets after any message is processed successfully.
      #     Default: 100
      def initialize(appender:, **args)
        @appender  = appender
        @processor = QueueProcessor.start(appender: appender, **args)
      end

      # Re-open appender after a fork.
      def reopen
        appender.reopen if appender.respond_to?(:reopen)
        processor.reopen
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
          processed:      processed_count,
          dropped:        dropped_count
        }
      end
    end
  end
end
