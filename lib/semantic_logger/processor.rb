module SemanticLogger
  # Thread that submits and processes log requests
  class Processor < Appender::Async
    # Allow the internal logger to be overridden from its default of STDERR
    #   Can be replaced with another Ruby logger or Rails logger, but never to
    #   SemanticLogger::Logger itself since it is for reporting problems
    #   while trying to log to the various appenders
    class << self
      attr_writer :logger
    end

    # Internal logger for SemanticLogger
    #   For example when an appender is not working etc..
    #   By default logs to STDERR
    def self.logger
      @logger ||=
        begin
          l      = SemanticLogger::Appender::File.new(io: STDERR, level: :warn)
          l.name = name
          l
        end
    end

    attr_reader :appenders

    def initialize(max_queue_size: -1)
      @appenders = Appenders.new(self.class.logger.dup)
      super(appender: @appenders, max_queue_size: max_queue_size)
    end

    # Start the appender thread
    def start
      return false if active?

      thread
      true
    end
  end
end
