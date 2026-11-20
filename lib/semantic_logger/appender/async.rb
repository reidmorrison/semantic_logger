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
                     :level, :level=, :formatter, :formatter=, :logger, :logger=, :console_stream,
                     :console_output?, :metrics_interval

      # Methods forwarded to the queue processor that owns the thread and queue.
      # Tuning options (max_queue_size, batch_size, non_blocking, ...) are set once at
      # construction via SemanticLogger.add_appender, so only the values that callers actually
      # read back are re-exposed here. lag_* and non_blocking= back the public
      # SemanticLogger.lag_* and SemanticLogger.non_blocking= API on the main Processor.
      def_delegators :@processor,
                     :log, :flush, :close, :renew_after_fork, :process_exiting=, :thread, :active?,
                     :worker_thread?, :holding_up?,
                     :queue, :max_queue_size, :capped?, :non_blocking?, :non_blocking=, :batch?,
                     :lag_check_interval, :lag_check_interval=,
                     :lag_threshold_s, :lag_threshold_s=,
                     :processed_count, :dropped_count, :failed_count

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
      #     Log the count of messages dropped because the queue was full, with non_blocking or once
      #     the worker thread has stopped (see async_max_retries), to the internal logger at most
      #     once every this number of seconds. Also limits how often messages discarded because
      #     they could not be written are reported, after the first.
      #     Default: 30
      #
      #   async_max_retries: [Integer]
      #     Maximum number of consecutive times to restart the worker thread (with a back-off)
      #     after it raises an exception while processing messages, before giving up and stopping
      #     the thread. The counter resets after any message is processed successfully.
      #     Once stopped, messages are dropped when the queue is full, rather than block.
      #     -1: Retry indefinitely and never stop the thread (the pre-v5 behaviour).
      #     Default: 100
      #
      # The proxy also answers #wrapped_logger, the logger that the appender writes to, when the
      # appender has one, such as one added with `logger:`, so that it is found the same way with or
      # without async: true. The proxy of any other appender does not respond to it.
      def initialize(appender:, **args)
        @appender  = appender
        @processor = QueueProcessor.start(appender: appender, **args)
        define_singleton_method(:wrapped_logger) { @appender.wrapped_logger } if appender.respond_to?(:wrapped_logger)
      end

      # Returns [String] the class and object address of this proxy, whether it batches, and the
      # wrapped appender's own #inspect, which shows only what that appender says is safe, but none of
      # the instance variables of this proxy or its queue processor. See Subscriber#inspect.
      def inspect
        address = Kernel.instance_method(:to_s).bind_call(self).delete_suffix(">")
        "#{address} batch=#{batch?} appender=#{appender.inspect}>"
      end

      # Hand the snapshot of metrics over to the worker thread, which gives it to the wrapped appender
      # between writes, without waiting for it (see QueueProcessor#hand_over), so that a slow
      # destination holds up nobody else. What the appender raises is reported, whatever its class,
      # not raised on the worker thread, since it is no failure to write a log message: it backs off
      # for none. Except a stack overflow, which is raised, as Appenders#log_metrics raises it, for
      # the worker thread to hand over to a new one.
      #
      # When no worker thread runs, each snapshot handed over is given to the appender on a thread of
      # its own (see QueueProcessor::Request#abandon), which may run while another one does, or while
      # a new worker thread flushes, closes or reopens the appender: a metric appender takes each
      # snapshot, and is flushed, closed and reopened, one call at a time, under a lock of its own
      # (see Metric::Snapshots).
      def log_metrics(snapshot)
        processor.hand_over do
          appender.log_metrics(snapshot)
        rescue SystemStackError
          raise
        rescue Exception => e
          processor.logger.error("Failed to write metrics to appender: #{name}", e)
        end
        true
      end

      # Re-open the wrapped appender and the queue processor, after a fork, or within the same
      # process, such as after a log rotation (see QueueProcessor#reopen).
      #
      # The wrapped appender is reopened by the worker thread, before it writes again, so that it
      # is never reopened while it is writing, and not in a signal trap, from which this is often
      # called. So this returns before it has reopened, and a reopen that fails, such as for a server
      # name that no longer resolves, is reported by the worker thread, which carries on. After a
      # fork, the child then always has a worker thread, which reopens the appender before it
      # writes anything.
      def reopen
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
      #                             was full: with non_blocking enabled, or once the worker
      #                             thread has stopped (see async_max_retries).
      #   failed:         [Integer] Cumulative number of log messages discarded because they
      #                             could not be written, whether their content or the
      #                             destination was at fault (see Subscriber#message_error?).
      def stats
        {
          name:           name,
          async:          true,
          thread_active:  active? || false,
          queue_size:     queue.size,
          capped:         capped?,
          max_queue_size: capped? ? max_queue_size : nil,
          processed:      processed_count,
          dropped:        dropped_count,
          failed:         failed_count
        }
      end
    end
  end
end
