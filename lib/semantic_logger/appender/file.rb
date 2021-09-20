# File appender
#
#   Writes log messages to a file or open iostream
#
module SemanticLogger
  module Appender
    class File < SemanticLogger::Subscriber
      attr_accessor :retry_count

      # Create a File Logger appender instance.
      #
      # Parameters
      #  file_name [String]
      #    Name of the file to write to.
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
      #  :retry_count [Integer]
      #   Number of times to attempt to re-open the file name when an error occurs trying to
      #   write to the file.
      #   Default: 1
      #   Note: Set to 0 to disable retries.
      #
      # Example
      #    require "semantic_logger"
      #
      #    # Enable trace level logging
      #    SemanticLogger.default_level = :info
      #
      #    # Log to a file
      #    SemanticLogger.add_appender(file_name: "application.log", formatter: :color)
      #
      #    logger = SemanticLogger["test"]
      #    logger.info "Hello World"
      def initialize(file_name, retry_count: true, **args, &block)
        if !file_name.is_a?(String) || file_name.empty?
          raise(ArgumentError, "SemanticLogging::Appender::File file_name must be a non-empty string")
        end

        @file_name   = file_name
        @retry_count = retry_count
        @log         = nil
        reopen

        super(**args, &block)
      end

      # After forking an active process call #reopen to re-open
      # open the file handles etc to resources.
      def reopen
        @log&.close rescue nil
        @log = ::File.open(@file_name, ::File::WRONLY | ::File::APPEND | ::File::CREAT)
        # Force all log entries to write immediately without buffering
        # Allows multiple processes to write to the same log file simultaneously
        @log.sync = true
        @log.set_encoding(Encoding::BINARY) if @log.respond_to?(:set_encoding)
        @log
      end

      # Since only one appender thread will be writing to the file at a time
      # it is not necessary to protect access to the file with a semaphore.
      def log(log)
        count = 0
        begin
          @log.write(formatter.call(log, self) << "\n")
        rescue StandardError => e
          if count < retry_count
            count += 1
            reopen
            retry
          end
          raise(e)
        end
        true
      end

      # Flush all pending logs to disk.
      #  Waits for all sent documents to be written to disk
      def flush
        @log.flush
      end
    end
  end
end
