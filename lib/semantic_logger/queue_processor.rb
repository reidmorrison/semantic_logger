require "forwardable"

module SemanticLogger
  # Internal class to process log messages from a queue.
  class QueueProcessor
    attr_reader :appender, :max_queue_size, :logger,
                :lag_check_interval, :lag_threshold_s, :async_max_retries, :batch_size, :batch_seconds,
                :queue, :thread, :retry_count, :signal

    def self.start(**args)
      processor = new(**args)
      processor.send(:create_thread)
      processor
    end

    def initialize(appender:, max_queue_size: 10_000, logger: nil,
                   lag_check_interval: 1_000, lag_threshold_s: 30, async_max_retries: 100,
                   batch: false, batch_size: 300, batch_seconds: 5)
      @appender           = appender
      @capped             = max_queue_size != -1
      @queue              = @capped ? SizedQueue.new(max_queue_size) : Queue.new
      @lag_check_interval = lag_check_interval
      @lag_threshold_s    = lag_threshold_s
      @async_max_retries  = async_max_retries
      @logger             = logger || appender.logger
      @retry_count        = 0
      @batch              = batch
      @batch_size         = batch_size
      @batch_seconds      = batch_seconds
      @signal             = Concurrent::Event.new

      return unless batch && !appender.respond_to?(:batch)

      raise(ArgumentError, "#{appender.class.name} does not support batching. It must implement #batch")
    end

    def log(log)
      queue << log

      # For batches wake up the processing thread once the number of queued messages has been exceeded.
      signal.set if batch? && (queue.size >= batch_size)

      true
    end

    def flush
      send_command(:flush)
    end

    def close
      send_command(:close)
    end

    def active?
      thread&.alive?
    end

    # Returns [true|false] whether the messages queue is capped.
    def capped?
      @capped
    end

    # Returns [true|false] whether the messages are being processed in batches.
    def batch?
      @batch
    end

    private

    attr_writer :thread, :retry_count

    # Submit command and wait for reply
    def send_command(command)
      return false unless active?

      queue_size = queue.size
      msg        = "QueueProcessor: Queued log messages: #{queue_size}, running command: #{command}"
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

    def create_thread
      self.thread = Thread.new { process }
    end

    # Process messages from the queue.
    def process
      # This thread is designed to never go down unless the main thread terminates
      # or the appender is closed.
      Thread.current.name = logger.name
      logger.trace "QueueProcessor: Processing messages"
      begin
        batch? ? process_messages_in_batches : process_messages
      rescue StandardError => e
        if retry_count < async_max_retries
          self.retry_count += 1
          safe_log(:warn, "QueueProcessor: Sleeping #{retry_count} second(s). Retry: #{retry_count}", e)
          sleep(retry_count)
          retry
        else
          safe_log(:error, "QueueProcessor: Stopping, exhausted #{retry_count} retries", e)
        end
      rescue Exception => e
        safe_log(:error, "QueueProcessor: Stopping due to a fatal exception", e)
      end
      safe_log(:trace, "QueueProcessor: Stopped processing messages")
    end

    def process_messages
      count = 0
      while (message = queue.pop)
        if message.is_a?(Log)
          appender.log(message)
          self.retry_count = 0
          count += 1
          # Check every few log messages whether this appender thread is falling behind
          if count > lag_check_interval
            check_lag(message)
            count = 0
          end
        else
          return unless process_command(message)
        end
      end
    end

    def process_messages_in_batches
      loop do
        # Wait for batch interval or number of messages to be exceeded.
        signal.wait(batch_seconds)

        logs          = []
        commands      = []
        message_count = queue.length
        message_count.times do
          # Queue#pop(true) raises an exception when there are no more messages, which is considered expensive.
          message = queue.pop
          if message.is_a?(Log)
            logs << message
            if logs.size >= batch_size
              appender.batch(logs)
              logs = []
              check_lag(message)
            end
          else
            commands << message
          end
        end
        appender.batch(logs) if logs.size.positive?
        self.retry_count = 0
        commands.each { |message| return unless process_command(message) }
        signal.reset unless queue.size >= batch_size
      end
    end

    # Returns false when message processing should be stopped
    def process_command(message)
      case message[:command]
      when :flush
        appender.flush
        message[:reply_queue] << true if message[:reply_queue]
      when :close
        appender.close
        message[:reply_queue] << true if message[:reply_queue]
        return false
      else
        logger.warn "QueueProcessor: Ignoring unknown command: #{message[:command]}"
      end
      true
    end

    def check_lag(log)
      diff = Time.now - log.time
      return unless diff > lag_threshold_s

      logger.warn "QueueProcessor: Fallen behind by #{diff} seconds with #{queue.size} messages queued up. Consider reducing the log level or changing the appenders"
    end

    def safe_log(level, message, exception = nil)
      # In case the file handles has already been released by Ruby
      logger.public_send(level, message, exception)
    rescue StandardError
      nil
    end
  end
end
