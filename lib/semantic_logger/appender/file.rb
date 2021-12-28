require "date"
# File appender
#
#   Writes log messages to a file or open iostream
#
module SemanticLogger
  module Appender
    class File < SemanticLogger::Subscriber
      attr_accessor :file_name, :retry_count, :append, :exclusive_lock, :encoding,
                    :reopen_period, :reopen_count, :reopen_size
      attr_reader :log_count, :log_size, :current_file_name, :reopen_at

      # Create an appender to log to a named file.
      #
      # Parameters
      #   file_name [String]
      #     Name of the file to write to.
      #
      #     File name format directives:
      #       %p - Process Id
      #       %n - Short hostname (SemanticLogger.host). Everything before the first period in the hostname.
      #       %N - Full hostname (SemanticLogger.host)
      #       %a - Application name (SemanticLogger.application)
      #       %e - Environment name (SemanticLogger.environment)
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
      #   :reopen_period [String]
      #     Specify a period after which to re-open the log file, specified in minutes, hours, or days.
      #     The format of the duration must start with an Integer or Float number,
      #     followed by the duration specified as:
      #       "m" : minutes
      #       "h" : hours
      #       "d" : days
      #     The time is rounded down to the specified time interval, so that:
      #     - "1h" will re-open every hour at the beginning of the hour.
      #     - "30m" will re-open every 30 minutes at the beginning of the 30th minute.
      #     - "1d" will re-open every day at midnight.
      #     Examples:
      #       "60m" : Every 60 minutes at the beginning of the minute: 10:24:00, 11:24:00, 12:24:00, ...
      #       "1h"  : Every hour at the beginning of the hour: 10:00:00, 11:00:00, 12:00:00, ...
      #       "1d"  : Every day at the beginning of the day: "20211008 00:00:00", "20211009 00:00:00", ...
      #     Default: nil (Disabled)
      #
      #   :reopen_count [Integer]
      #     Close and re-open the log file after every `reopen_count` number of logged entries.
      #     Default: 0 (Disabled)
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
      #     Default: 0 (Disabled)
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
      def initialize(file_name, retry_count: 1, append: true, reopen_period: nil, reopen_count: 0, reopen_size: 0, encoding: Encoding::BINARY, exclusive_lock: false, **args, &block)
        if !file_name.is_a?(String) || file_name.empty?
          raise(ArgumentError, "SemanticLogging::Appender::File file_name must be a non-empty string")
        end

        @file_name      = file_name
        @retry_count    = retry_count
        @file           = nil
        @append         = append
        @reopen_period  = reopen_period
        @reopen_count   = reopen_count
        @reopen_size    = reopen_size
        @encoding       = encoding
        @exclusive_lock = exclusive_lock
        @log_count      = 0
        @log_size       = 0
        @reopen_at      = nil

        super(**args, &block)
      end

      # After forking an active process call #reopen to re-open
      # open the file handles etc to resources.
      def reopen
        begin
          @file&.close
        rescue StandardError
          nil
        end

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

        self.reopen_at = reopen_period ? next_reopen_period(reopen_period) : nil

        options = ::File::WRONLY | ::File::CREAT
        options |= ::File::APPEND if append
        @file = ::File.open(current_file_name, options)
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

      attr_writer :log_count, :log_size, :current_file_name, :reopen_at

      def time_to_reopen?
        return true unless @file

        (reopen_count.positive? && (log_count >= reopen_count)) ||
          (reopen_size.positive? && (log_size >= reopen_size)) ||
          (reopen_at && (Time.now > reopen_at))
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
        when "a"
          SemanticLogger.application
        when "e"
          SemanticLogger.environment
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

      def next_reopen_period(period_string)
        return unless period_string

        duration, period = parse_period(period_string)
        calculate_reopen_at(duration, period)
      end

      def parse_period(period_string)
        match = period_string.to_s.downcase.gsub(/\s+/, "").match(/([\d.]+)([mhd])/)
        unless match
          raise(ArgumentError,
                "Invalid period definition: #{period_string}, must begin with an integer, followed by m,h, or d.")
        end

        duration = match[1]
        period   = match[2]
        raise(ArgumentError, "Invalid or missing duration in: #{period_string}, must begin with an integer.") unless duration
        raise(ArgumentError, "Invalid or missing period in: #{period_string}, must end with m,h, or d.") unless period

        [duration.to_i, period]
      end

      # Round down the current time based on the period, then add on the duration for that period
      def calculate_reopen_at(duration, period, time = Time.now)
        case period
        when "m"
          Time.new(time.year, time.month, time.day, time.hour, time.min, 0) + (duration * 60)
        when "h"
          Time.new(time.year, time.month, time.day, time.hour, 0, 0) + (duration * 60 * 60)
        when "d"
          Time.new(time.year, time.month, time.day, 0, 0, 0) + (duration * 24 * 60 * 60)
        else
          raise(ArgumentError, "Invalid or missing period in: #{reopen_period}, must end with m,h, or d.")
        end
      end
    end
  end
end
