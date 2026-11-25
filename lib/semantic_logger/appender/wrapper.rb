# Send log messages to any standard Ruby logging class.
#
#  Forwards logging call to loggers such as Logger, log4r, etc.
module SemanticLogger
  module Appender
    class Wrapper < SemanticLogger::Subscriber
      # The logger this appender writes to. Not #logger, which is the internal logger that this
      # appender reports its own problems to, as every appender does (see Subscriber#logger).
      attr_reader :wrapped_logger

      # Forward all logging calls to the supplied logging instance.
      #
      # Parameters
      #   logger: [Object]
      #     Instance of an existing logger conforming to the Ruby Logger methods.
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: none (:trace), so it writes every entry that a logger emits; each logger
      #     filters by its own level.
      #
      #   formatter: [Object|Proc]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: Use the built-in formatter (See: #call)
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      #
      # Ruby Logger
      #    require 'logger'
      #    require 'semantic_logger'
      #
      #    ruby_logger = Logger.new($stdout)
      #    SemanticLogger.add_appender(logger: ruby_logger)
      #
      #    logger =  SemanticLogger['test']
      #    logger.info('Hello World', some: :payload)
      #
      # Install the `rails_semantic_logger` gem to replace the Rails logger with Semantic Logger.
      def initialize(logger:, **args, &)
        @wrapped_logger = logger

        # Check if the custom appender responds to all the log levels. For example Ruby ::Logger
        does_not_implement = LEVELS[1..].find { |i| !@wrapped_logger.respond_to?(i) }
        if does_not_implement
          raise(ArgumentError,
                "Supplied logger does not implement:#{does_not_implement}. " \
                "It must implement all of #{LEVELS[1..].inspect}")
        end

        super(**args, &)
      end

      # Pass log calls to the underlying Rails, log4j or Ruby logger
      #  trace entries are mapped to debug since :trace is not supported by the
      #  Ruby or Rails Loggers
      def log(log)
        level = log.level == :trace ? :debug : log.level
        @wrapped_logger.send(level, format_log(log))
        true
      end

      # Flush all pending logs to disk.
      #  Waits for all queued log messages to be written to disk.
      def flush
        @wrapped_logger.flush if @wrapped_logger.respond_to?(:flush)
      end

      # Close underlying log
      #  Waits for all queued log messages to be written to disk.
      def close
        @wrapped_logger.close if @wrapped_logger.respond_to?(:close)
      ensure
        super
      end
    end
  end
end
