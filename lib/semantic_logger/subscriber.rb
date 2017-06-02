# Abstract Subscriber
#
#   Abstract base class for appender and metrics subscribers.
module SemanticLogger
  class Subscriber < SemanticLogger::Base
    # Every logger has its own formatter
    attr_accessor :formatter
    attr_writer :application, :host

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

    # Returns [SemanticLogger::Formatters::Default] default formatter for this subscriber.
    def default_formatter
      SemanticLogger::Formatters::Default.new
    end

    # Allow application name to be set globally or on a per subscriber basis.
    def application
      @application || SemanticLogger.application
    end

    # Allow host name to be set globally or on a per subscriber basis.
    def host
      @host || SemanticLogger.host
    end

    private

    # Initializer for Abstract Class SemanticLogger::Subscriber
    #
    # Parameters
    #   level: [:trace | :debug | :info | :warn | :error | :fatal]
    #     Override the log level for this subscriber.
    #     Default: :error
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
    def initialize(level: nil, formatter: nil, filter: nil, application: nil, host: nil, &block)
      @formatter   = Formatters.factory(formatter, &block) || (respond_to?(:call) ? self : default_formatter)
      @application = application
      @host        = host

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

  end
end
