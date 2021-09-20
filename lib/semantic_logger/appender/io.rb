# File appender
#
#   Writes log messages to a file or open iostream
#
module SemanticLogger
  module Appender
    class IO < SemanticLogger::Subscriber
      # Create a Stream Logger appender instance.
      #
      # Parameters
      #  io [IO]
      #    An IO stream to which to write the log messages to.
      #
      #  :level [:trace | :debug | :info | :warn | :error | :fatal]
      #    Override the log level for this appender.
      #    Default: SemanticLogger.default_level
      #
      #  :formatter: [Object|Proc]
      #    An instance of a class that implements #call, or a Proc to be used to format
      #    the output from this appender
      #    Default: Use the built-in formatter (See: #call)
      #
      #  :filter [Regexp|Proc]
      #    RegExp: Only include log messages where the class name matches the supplied
      #    regular expression. All other messages will be ignored.
      #    Proc: Only include log messages where the supplied Proc returns true
      #          The Proc must return true or false.
      #
      # Example
      #    require "semantic_logger"
      #
      #    # Enable trace level logging
      #    SemanticLogger.default_level = :info
      #
      #    # Log to screen
      #    SemanticLogger.add_appender(io: $stdout, formatter: :color)
      #
      #    logger = SemanticLogger['test']
      #    logger.info 'Hello World'
      def initialize(io, **args, &block)
        @io = io
        unless @io.respond_to?(:write)
          raise(ArgumentError, "SemanticLogging::Appender::IO io is not a valid IO instance: #{io.inspect}")
        end

        super(**args, &block)
      end

      def log(log)
        # Since only one appender thread will be writing to the file at a time
        # it is not necessary to protect access to the file with a semaphore
        # Allow this logger to filter out log levels lower than it's own
        @io.write(formatter.call(log, self) << "\n")
        true
      end

      # Flush all pending logs to disk.
      #  Waits for all sent documents to be written to disk
      def flush
        @io.flush if @io.respond_to?(:flush)
      end

      def console_output?
        [$stderr, $stdout].include?(@io)
      end
    end
  end
end
