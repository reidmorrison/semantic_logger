module SemanticLogger
  module Appender
    # Allow any appender to run asynchronously in a separate thread.
    class Async
      attr_accessor :logger, :lag_check_interval, :lag_threshold_s
      attr_reader :queue, :appender

      # Appender facade to allow an existing appender to run asynchronously in a separate thread.
      #
      # Parameters:
      #   name: [String]
      #     Name to use for the log thread and the log name when logging any errors from this appender.
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
      def initialize(appender:,
                     name: appender.class.name,
                     max_queue_size: 10_000,
                     lag_check_interval: 1_000,
                     lag_threshold_s: 30)

        # Its own error logger instance
        @logger      = Processor.send(:logger).dup
        @logger.name = name

        @appender           = appender
        @lag_check_interval = lag_check_interval
        @lag_threshold_s    = lag_threshold_s

        if max_queue_size == -1
          @queue  = Queue.new
          @capped = false
        else
          @queue  = SizedQueue.new(max_queue_size)
          @capped = true
        end
        thread
      end

      # Returns [true|false] if the queue has a capped size.
      def capped?
        @capped
      end

      # Returns [Thread] the worker thread.
      #
      # Starts the worker thread if not running.
      def thread
        return @thread if @thread && @thread.alive?
        @thread = Thread.new { process_requests }
      end

      # Returns true if the worker thread is active
      def active?
        @thread && @thread.alive?
      end

      # Add log message for processing.
      def log(log)
        queue << log
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

      # Separate thread for batching up log messages before writing.
      def process_requests
        # This thread is designed to never go down unless the main thread terminates
        # or the appender is closed.
        Thread.current.name = logger.name
        logger.trace "Appender thread active"
        begin
          count = 0
          while message = queue.pop
            if message.is_a?(Log)
              appender.log(message)
              count += 1
              # Check every few log messages whether this appender thread is falling behind
              if count > lag_check_interval
                if (diff = Time.now - message.time) > lag_threshold_s
                  logger.warn "Appender thread has fallen behind by #{diff} seconds with #{queue_size} messages queued up. Consider reducing the log level or changing the appenders"
                end
                count = 0
              end
            else
              case message[:command]
              when :flush
                appender.flush
                message[:reply_queue] << true if message[:reply_queue]
              when :close
                appender.close
                message[:reply_queue] << true if message[:reply_queue]
                break
              else
                logger.warn "Appender thread: Ignoring unknown command: #{message[:command]}"
              end
            end
          end
        rescue Exception => exception
          # This block may be called after the file handles have been released by Ruby
          begin
            logger.error 'Restarting due to exception', exception
          rescue Exception
            nil
          end
          retry
        ensure
          @thread = nil
          # This block may be called after the file handles have been released by Ruby
          begin
            logger.trace 'Thread has stopped'
          rescue Exception
            nil
          end
        end
      end

      # Submit command and wait for reply
      def submit_request(command)
        return false unless active?

        queue_size = queue.size
        msg = "Too many queued log messages: #{queue_size}, running command: #{command}"
        if queue_size > 1_000
          logger.warn msg
        elsif queue_size > 100
          logger.info msg
        elsif queue_size > 0
          logger.trace msg
        end

        reply_queue = Queue.new
        queue << {command: command, reply_queue: reply_queue}
        reply_queue.pop
      end

    end
  end
end
