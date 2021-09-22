require "date"
# File appender
#
#   Writes log messages to a file or open iostream
#
module SemanticLogger
  module Appender
    class File < SemanticLogger::Subscriber
      attr_accessor :file_name, :retry_count, :append, :exclusive_lock, :reopen_count, :reopen_size, :encoding
      attr_reader :log_count, :log_size, :current_file_name

      # Create an appender to log to a named file.
      #
      # Parameters
      #   file_name [String]
      #     Name of the file to write to.
      #
      #     File name format directives:
      #       %p - Process Id
      #       %n - Short hostname. Everything before the first period in the hostname.
      #       %N - Full hostname.
      #       %D - Current Date. Equivalent to "%Y%m%d"
      #       %T - Current Time. Equivalent to "%H%M%S"
      #       %% - Literal `%` character
      #
      #     Date:
      #       %Y - Year with century
      #       %C - year / 100 (round down.  20 in 2009)
      #       %y - year % 100 (00..99)
      #       %m - Month of the year, zero-padded (01..12)
      #       %d - Day of the month, zero-padded (01..31)
      #       %j - Day of the year (001..366)
      #       %U - Week number of the year.  The week starts with Sunday.  (00..53)
      #       %W - Week number of the year.  The week starts with Monday.  (00..53)
      #
      #     Time:
      #       %H - 24 Hour of the day, zero-padded (00..23)
      #       %M - Minute of the hour (00..59)
      #       %S - Second of the minute (00..60)
      #
      #     Examples:
      #       Create a log file name consisting of the short host name, process id, date, and time.
      #         "log/production-%n-%p-%D-%T.log"
      #
      #   :level [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: SemanticLogger.default_level
      #
      #   :formatter: [Object|Proc]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: Use the built-in formatter (See: #call)
      #
      #   :filter [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      #
      #   :append [true|false]
      #     Append to the log file if already present?
      #     Default: true
      #
      #   :exclusive_lock [true|false]
      #     Obtain an exclusive lock on the file, for operating systems that support it.
      #     Prevents multiple processes from trying to write to the same log file.
      #     Default: false
      #
      #   :encoding ["UTF-8", "UTF-16", etc.]
      #     Encoding to use when writing to the file.
      #     Default: Encoding::BINARY
      #
      #   :retry_count [Integer]
      #     Number of times to attempt to re-open the file name when an error occurs trying to
      #     write to the file.
      #     Note: Set to 0 to disable retries.
      #     Default: 1
      #
      #   :reopen_count [Integer]
      #     Close and re-open the log file after every `reopen_count` number of logged entries.
      #     Default: nil
      #
      #   :reopen_size [Integer]
      #     Approximate number of bytes to write to a log file by this process before closing and re-opening it.
      #     Notes:
      #     - When `append: true` and the file already exists, it reads the size of the current log file
      #       and starts with that size.
      #       - If the current log file size already exceeds the `reopen_size`, its current size is ignored.
      #     - The `reopen_size` is only the amount of bytes written by this process, it excludes data
      #       written by other processes. Use a unique filename to prevent multiple processes from writing to
      #       the same log file at the same time.
      #     Default: nil
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
      def initialize(file_name, retry_count: 1, append: true, reopen_count: nil, reopen_size: nil, encoding: Encoding::BINARY, **args, &block)
        if !file_name.is_a?(String) || file_name.empty?
          raise(ArgumentError, "SemanticLogging::Appender::File file_name must be a non-empty string")
        end

        @file_name    = file_name
        @retry_count  = retry_count
        @file         = nil
        @append       = append
        @reopen_count = reopen_count
        @reopen_size  = reopen_size
        @encoding     = encoding
        @log_count    = 0
        @log_size     = 0

        super(**args, &block)
      end

      # After forking an active process call #reopen to re-open
      # open the file handles etc to resources.
      def reopen
        @file&.close rescue nil

        self.current_file_name = apply_format_directives(file_name)
        if ::File.directory?(file_name)
          raise(ArgumentError, "The supplied log file_name: #{current_file_name} is already a directory.")
        end

        self.log_count = 0
        if append && reopen_size && ::File.exist?(current_file_name)
          self.log_size = ::File.size(current_file_name)
          self.log_size = 0 if log_size >= reopen_size
        else
          self.log_size = 0
        end

        options = ::File::WRONLY | ::File::CREAT
        options |= ::File::APPEND if append
        @file   = ::File.open(current_file_name, options)
        # Force all log entries to write immediately without buffering
        # Allows multiple processes to write to the same log file simultaneously
        @file.sync = true
        @file.set_encoding(encoding) if @file.respond_to?(:set_encoding)
        @file.flock(::File::LOCK_EX) if exclusive_lock
        @file
      end

      # Since only one appender thread will be writing to the file at a time
      # it is not necessary to protect access to the file with a semaphore.
      def log(log)
        reopen if time_to_reopen?

        count = 0
        begin
          message = formatter.call(log, self) << "\n"
          @file.write(message)
          @log_count += 1
          @log_size  += message.size
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
        @file&.flush
      end

      private

      attr_writer :log_count, :log_size, :current_file_name

      def time_to_reopen?
        return true unless @file

        if (reopen_count && (log_count >= reopen_count)) ||
          (reopen_size && (log_size >= reopen_size))
          return true
        end

        # Possible future enhancement to support time based log rotation
        #   :reopen_interval [:hour|:day|:week|:month|Integer]
        #     :hour     Close and re-open the log file every hour on the hour.
        #     :day      Close and re-open the log file every day at midnight.
        #     :week     Close and re-open the log file every week starting at 12am every Monday.
        #     Integer   When an integer value, the number of minutes between closing and re-opening the log file.
        #     Notes:
        #     - Log rotation can be achieved by including a date and time pattern in the log file name.
        #       With every re-open the date and time pattern is re-evaluated.

        false
      end

      def apply_format_directives(file_name)
        return file_name unless file_name.include?("%")

        file_name.gsub(/%(.)/) { format_directive(Regexp.last_match(1)) }
      end

      def format_directive(directive)
        case directive
        when "p"
          $$
        when "n"
          SemanticLogger.host.split(".")[0]
        when "N"
          SemanticLogger.host
        when "D"
          Date.today.strftime("%Y%m%d")
        when "Y", "C", "y", "m", "d", "j", "U", "W"
          Date.today.strftime("%#{directive}")
        when "T"
          Time.now.strftime("%H%M%S")
        when "H", "M", "S"
          Time.now.strftime("%#{directive}")
        when "%"
          "%"
        else
          raise(ArgumentError, "Format Directive '#{directive}' in file_name: #{file_name} is not supported.")
        end
      end
    end
  end
end
