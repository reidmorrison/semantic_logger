module SemanticLogger
  # Thread that submits and processes log requests
  class SyncProcessor
    extend Forwardable

    # Forward methods that can be called directly
    def_delegator :@appenders, :add
    def_delegator :@appenders, :log
    def_delegator :@appenders, :flush
    def_delegator :@appenders, :close
    def_delegator :@appenders, :reopen

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

    def initialize(appenders = nil)
      @appenders = appenders || Appenders.new(self.class.logger.dup)
    end

    def start
      # NOP
    end
  end
end
