module SemanticLogger
  module Appender
    # Log asynchronously in batches using a separate thread.
    #
    # Log messages are grouped up and only logged when:
    # * The number of queued messages is exceeded.
    # * Or, the appropriate amount of time has passed since the last batch was sent.
    class AsyncBatch < Async
      attr_accessor :batch_size, :batch_seconds
      attr_reader :signal

      # Batching Appender proxy for appenders that support batches.
      #
      # Parameters:
      #   batch_size: [Integer]
      #     Maximum number of messages to batch up before sending.
      #     Default: 300
      #
      #   batch_seconds: [Integer]
      #     Maximum number of seconds between sending batches.
      #     Default: 5
      #
      # See SemanticLogger::Appender::Async for other paramaters
      #
      # Note:
      # * `lag_check_interval` is not applicable to batches, since the first message of every batch
      #   is the oldest and is always checked to see if the lag interval has been exceeded.
      def initialize(appender:,
                     max_queue_size: 10_000,
                     lag_threshold_s: 30,
                     batch_size: 300,
                     batch_seconds: 5)

        @batch_size    = batch_size
        @batch_seconds = batch_seconds
        @signal        = Concurrent::Event.new
        super(
          appender:        appender,
          max_queue_size:  max_queue_size,
          lag_threshold_s: lag_threshold_s
        )

        return if appender.respond_to?(:batch)

        raise(ArgumentError, "#{appender.class.name} does not support batching. It must implement #batch")
      end

      # Add log message for processing.
      def log(log)
        result = super(log)
        # Wake up the processing thread since the number of queued messages has been exceeded.
        signal.set if queue.size >= batch_size
        result
      end

      private

      # Separate thread for batching up log messages before writing.
      def process_messages
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
          appender.batch(logs) if logs.size.positive?
          messages.each { |message| process_message(message) }
          signal.reset unless queue.size >= batch_size
        end
      end

      def submit_request(command)
        # Wake up the processing thread to process this command immediately.
        signal.set
        super
      end
    end
  end
end
