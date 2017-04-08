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
      @formatter   = extract_formatter(formatter, &block)
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

    # Return formatter that responds to call.
    #
    # Supports formatter supplied as:
    # - Symbol
    # - Hash ( Symbol => { options })
    # - Instance of any of SemanticLogger::Formatters
    # - Proc
    # - Any object that responds to :call
    # - If none of the above apply, then the supplied block is returned as the formatter.
    # - Otherwise an instance of the default formatter is returned.
    def extract_formatter(formatter, &block)
      case
      when formatter.is_a?(Symbol)
        SemanticLogger::Appender.constantize_symbol(formatter, 'SemanticLogger::Formatters').new
      when formatter.is_a?(Hash) && formatter.size > 0
        fmt, options = formatter.first
        SemanticLogger::Appender.constantize_symbol(fmt.to_sym, 'SemanticLogger::Formatters').new(options)
      when formatter.respond_to?(:call)
        formatter
      when block
        block
      when respond_to?(:call)
        self
      else
        default_formatter
      end
    end

  end
end
