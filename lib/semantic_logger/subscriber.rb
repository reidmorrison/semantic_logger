# Abstract Subscriber
#
#   Abstract base class for all appenders.
module SemanticLogger
  class Subscriber < SemanticLogger::Base
    # Every appender has its own formatter
    attr_reader :formatter
    attr_writer :application, :environment, :host, :logger, :metrics

    # Returns the current log level if set, otherwise it logs everything it receives.
    def level
      @level || :trace
    end

    # A subscriber should implement flush if it can.
    def flush
      # NOOP
    end

    # A subscriber should implement close if it can.
    def close
      # NOOP
    end

    # Method called to log an event
    def log(log)
      raise NotImplementedError
    end

    # Returns [SemanticLogger::Formatters::Default] default formatter for this subscriber.
    def default_formatter
      SemanticLogger::Formatters::Default.new
    end

    # Allow application name to be set globally or on a per subscriber basis.
    def application
      @application || SemanticLogger.application
    end

    # Allow environment name to be set globally or on a per subscriber basis.
    def environment
      @environment || SemanticLogger.environment
    end

    # Allow host name to be set globally or on a per subscriber basis.
    def host
      @host || SemanticLogger.host
    end

    # Give each appender its own logger for logging.
    # For example trace messages sent to services or errors when something fails.
    def logger
      @logger ||=
        begin
          logger      = SemanticLogger::Processor.logger.clone
          logger.name = self.class.name
          logger
        end
    end

    # Set the formatter from Symbol|Hash|Block
    def formatter=(formatter)
      @formatter =
        if formatter.nil?
          respond_to?(:call) ? self : default_formatter
        else
          Formatters.factory(formatter)
        end
    end

    # Whether this log entry meets the criteria to be logged by this appender.
    def should_log?(log)
      super(log) && (log.metric_only? ? metrics? : true)
    end

    # Whether this appender is logging to stdout or stderror
    def console_output?
      false
    end

    private

    # Initializer for Abstract Class SemanticLogger::Subscriber
    #
    # Parameters
    #   level: [:trace | :debug | :info | :warn | :error | :fatal]
    #     Override the log level for this subscriber.
    #
    #   formatter: [Object|Proc]
    #     An instance of a class that implements #call, or a Proc to be used to format
    #     the output from this subscriber
    #     Default: Use the built-in formatter (See: #call)
    #
    #   filter: [Regexp|Proc]
    #     RegExp: Only include log messages where the class name matches the supplied.
    #     regular expression. All other messages will be ignored.
    #     Proc: Only include log messages where the supplied Proc returns true
    #           The Proc must return true or false.
    #
    #   application: [String]
    #     Name of this application to appear in log messages.
    #     Default: SemanticLogger.application
    #
    #   host: [String]
    #     Name of this host to appear in log messages.
    #     Default: SemanticLogger.host
    #
    #   metrics: [Boolean]
    #     Whether to log metric only entries with this subscriber.
    #     Default: false
    def initialize(level: nil, formatter: nil, filter: nil, application: nil, environment: nil, host: nil, metrics: false, &block)
      self.formatter = block || formatter
      @application   = application
      @environment   = environment
      @host          = host
      @metrics       = metrics

      # Subscribers don't take a class name, so use this class name if a subscriber
      # is logged to directly.
      super(self.class, level, filter)
    end

    # Return the level index for fast comparisons.
    # Returns the lowest level index if the level has not been explicitly
    # set for this instance.
    def level_index
      @level_index || 0
    end

    # Whether to log metric only entries with this subscriber
    def metrics?
      @metrics
    end
  end
end
