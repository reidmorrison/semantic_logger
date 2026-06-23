module SemanticLogger
  # Thread that submits and processes log requests
  class Processor < Appender::Async
    # Allow the internal logger to be overridden from its default of $stderr
    #   Can be replaced with another Ruby logger or Rails logger, but never to
    #   SemanticLogger::Logger itself since it is for reporting problems
    #   while trying to log to the various appenders
    class << self
      attr_writer :logger
    end

    # Internal logger for SemanticLogger
    #   For example when an appender is not working etc..
    #   By default logs to $stderr
    def self.logger
      @logger ||=
        begin
          l      = SemanticLogger::Appender::IO.new($stderr, level: :warn)
          l.name = name
          l
        end
    end

    attr_reader :appenders

    def initialize(max_queue_size: 10_000)
      @appenders = Appenders.new(self.class.logger.dup)
      super(appender: @appenders, max_queue_size: max_queue_size)
    end

    # Start the appender thread
    def start
      return false if active?

      thread
      true
    end

    # Returns [Hash] operational statistics for the logging pipeline.
    #
    #   queue_size:     [Integer] Number of log messages waiting on the main pipeline queue.
    #   capped:         [Boolean] Whether the main queue has a maximum size.
    #   max_queue_size: [Integer] Maximum queue size, or nil when uncapped.
    #   thread_active:  [Boolean] Whether the main pipeline thread is running.
    #   processed:      [Integer] Cumulative number of log messages processed since startup.
    #   dropped:        [Integer] Cumulative number of log messages dropped at the main queue.
    #   appenders:      [Array<Hash>] Per-appender statistics, see Appenders#stats.
    def stats
      {
        queue_size:     queue.size,
        capped:         capped?,
        max_queue_size: capped? ? max_queue_size : nil,
        thread_active:  active? || false,
        processed:      @processed_count,
        dropped:        @dropped_count,
        appenders:      appenders.stats
      }
    end
  end
end
