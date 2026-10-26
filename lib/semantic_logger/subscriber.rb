# Abstract Subscriber
#
#   Abstract base class for all appenders.
module SemanticLogger
  class Subscriber < SemanticLogger::Base
    # Every appender has its own formatter
    attr_reader :formatter
    attr_writer :application, :environment, :host, :logger, :metrics

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
      super && (log.metric_only? ? metrics? : true)
    end

    # The console stream this appender writes to, if any.
    # Returns one of :stdout, :stderr, or nil when not writing to a console stream.
    def console_stream
      nil
    end

    # Whether this appender is logging to stdout or stderr.
    def console_output?
      !console_stream.nil?
    end

    # Whether an appender that implements #batch should be wrapped in a batch
    # proxy automatically. Appenders that support batching but should only batch
    # when explicitly requested (via `batch: true`) override this to return false.
    def batch_by_default?
      true
    end

    # Errors raised by formatting a log message whose content cannot be written, such as a
    # value that cannot be serialized. Excludes JSON::ParserError, which comes from parsing a
    # response rather than from the message, except its subclass JSON::NestingError, which
    # JSON.generate raises for a value nested too deeply.
    MESSAGE_ERRORS = [JSON::GeneratorError, JSON::NestingError, EncodingError, FloatDomainError].freeze

    # Whether the supplied exception, raised by #log or #batch, was caused by the content of a
    # log message, rather than by the destination, for example being unavailable.
    #
    # Retrying cannot write such a message, so an asynchronous appender discards it and carries
    # on, instead of backing off and retrying. Any other exception is retried with a back-off.
    #
    # An appender that raises its own errors for bad content can override this to recognize them.
    def message_error?(exception)
      MESSAGE_ERRORS.any? { |error_class| exception.is_a?(error_class) }
    end

    # Whether #batch writes none of the log messages when it raises a message error (see
    # #message_error?), for example because it formats every message before sending any.
    #
    # When true, a batch that fails with a message error is split up and each part retried,
    # so that only the offending message is discarded. When false, retrying could write some
    # messages twice, so the whole batch is discarded instead.
    def batch_all_or_nothing?
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
    def initialize(level: nil, formatter: nil, filter: nil, application: nil, environment: nil, host: nil,
                   metrics: false, &block)
      self.formatter = block || formatter
      @application   = application
      @environment   = environment
      @host          = host
      @metrics       = metrics

      # Subscribers don't take a class name, so use this class name if a subscriber
      # is logged to directly.
      super(self.class, level, filter)
    end

    # Without a level of its own, a subscriber logs everything it receives.
    def fallback_level
      :trace
    end

    def fallback_level_index
      0
    end

    # Whether to log metric only entries with this subscriber
    def metrics?
      @metrics
    end
  end
end
