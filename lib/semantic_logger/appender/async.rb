require "forwardable"

module SemanticLogger
  module Appender
    # Allow any appender to run asynchronously in a separate thread.
    class Async
      extend Forwardable

      attr_reader :appender

      # Forward methods that can be called directly
      def_delegators :@appender, :name, :should_log?, :filter,
                     :host, :application, :environment,
                     :level, :level=, :logger, :logger=
      def_delegators :@processor, :active?, :capped?, :max_queue_size,
                     :lag_check_interval, :lag_threshold_s, :async_max_retries,
                     :batch?, :batch_size, :batch_seconds, :queue

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
      #   lag_threshold_s: [Float]
      #     Log a warning when a log message has been on the queue for longer than this period in seconds.
      #     Default: 30
      #
      #   lag_check_interval: [Integer]
      #     Number of messages to process before checking for slow logging.
      #     Default: 1,000
      #     Note: Not applicable when batch: `true`.
      #
      #   async_max_retries: [Integer]
      #     Maximum number of consecutive failed attempts when trying to log to an appender.
      #     Default: 100
      #
      #   batch: [true|false]
      #     Process log messages in batches for appenders that support batches.
      #     Note: Appenders must implement the `batch` method.
      #
      #   batch_size: [Integer]
      #     Maximum number of messages to batch up before sending.
      #     Default: 300
      #     Note: Only applicable when batch: `true`
      #
      #   batch_seconds: [Integer]
      #     Maximum number of seconds between sending batches.
      #     Default: 5
      #     Note: Only applicable when batch: `true`
      def initialize(appender:, **args)
        @appender = appender
        @args     = args
        create_processor
      end

      # Re-open appender after a fork
      def reopen
        # When #reopen is called without forking, cleanup running thread.
        close if !closed? && active?

        appender.reopen if appender.respond_to?(:reopen)
        create_processor
        true
      end

      # Add log message for processing.
      def log(log)
        return false if closed?

        processor.log(log)
      end

      # Flush all queued log entries disk, database, etc.
      #  All queued log messages are written and then each appender is flushed in turn.
      def flush
        return false if closed?

        processor.flush
      end

      # Close all appenders and flush any outstanding messages.
      # Ignores multiple close requests.
      # Only returns once the messages have been flushed to disk.
      def close
        return false if closed?

        @closed = true
        processor.close
      end

      def closed?
        @closed
      end

      private

      attr_reader :args, :processor

      def create_processor
        @processor = QueueProcessor.start(appender: appender, **args)
        @closed    = false
      end
    end
  end
end
