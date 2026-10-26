require "date"
# File appender
#
#   Writes log messages to a file or open iostream
#
module SemanticLogger
  module Appender
    class File < SemanticLogger::Subscriber
      attr_accessor :file_name, :retry_count, :append, :exclusive_lock, :encoding,
                    :reopen_period, :reopen_count, :reopen_size, :permissions
      attr_reader :log_count, :log_size, :current_file_name, :reopen_at

      # With permissions, the log file is opened without following a symbolic link, so that a link
      # planted in the log directory can neither create nor open the file it points at, without
      # blocking, so that a planted FIFO fails to open instead of waiting for a reader, and without
      # becoming the controlling terminal.
      SECURE_OPEN_FLAGS = ::File::NOFOLLOW | ::File::NONBLOCK | ::File::NOCTTY
      # Seconds to wait before opening a refused log file again.
      REFUSED_RETRY_INTERVAL = 5
      private_constant :SECURE_OPEN_FLAGS, :REFUSED_RETRY_INTERVAL

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
      #   :permissions [Integer]
      #     Octal file permissions to apply to the log file.
      #     Log files frequently contain sensitive information, so restrict access
      #     by supplying for example `0o640` (owner read/write, group read).
      #     Applied both when the file is created and to an existing log file, which must be
      #     a regular file owned by the process, with a single hard link, that the file_name
      #     names directly rather than through a symbolic link. Nothing is written to any
      #     other file, or when the file cannot be opened: the appender raises IOError when it
      #     is created, and when the file is later reopened, it reports why and writes nothing
      #     until the file is fixed, trying again every few seconds.
      #     Default: nil (use the process umask, the standard Ruby behavior)
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
      def initialize(file_name, retry_count: 1, append: true, reopen_period: nil, reopen_count: 0, reopen_size: 0,
                     encoding: Encoding::BINARY, exclusive_lock: false, permissions: nil, **args, &)
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
        @permissions    = permissions
        @log_count      = 0
        @log_size       = 0
        @reopen_at      = nil

        super(**args, &)

        # Open the file at creation time so that misconfiguration (bad directory,
        # insufficient permissions, ...) raises immediately in SemanticLogger.add_appender,
        # instead of surfacing later on the appender thread via the internal logger. With
        # permissions, a refused log file raises IOError (see #open_with_permissions).
        raise(IOError, refusal_message, cause: @refusal_cause) unless reopen
      end

      # After forking an active process call #reopen to re-open
      # open the file handles etc to resources.
      def reopen
        close_quietly(@file)

        self.current_file_name = apply_format_directives(file_name)
        # With permissions, a directory is refused when it fails to open, like any other file.
        if !permissions && ::File.directory?(current_file_name)
          raise(ArgumentError, "The supplied log file_name: #{current_file_name} is already a directory.")
        end

        self.log_count = 0
        # File.size? rather than File.size, since the file can be removed at any time.
        size = ::File.size?(current_file_name) if append && reopen_size
        self.log_size = size && size < reopen_size ? size : 0

        self.reopen_at = reopen_period ? next_reopen_period(reopen_period) : nil

        options = ::File::WRONLY | ::File::CREAT
        options |= ::File::APPEND if append
        @file = permissions ? open_with_permissions(options) : ::File.open(current_file_name, options)
        return unless @file

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
        # Read once, since #reopen can be called from another thread meanwhile.
        file = time_to_reopen? ? reopen : @file
        return refused unless file

        # Formatted once, outside the retry below: reopening the file cannot fix the content.
        message = format_log(log) << "\n"
        count   = 0
        begin
          file.write(message)
          @log_count += 1
          @log_size  += message.size
        rescue StandardError => e
          if count < retry_count
            count += 1
            file = reopen
            return refused unless file

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

      # See Subscriber#inspect.
      def inspect_details
        "file_name=#{file_name.inspect}"
      end

      private

      attr_writer :log_count, :log_size, :current_file_name, :reopen_at

      # Opens the log file and applies the permissions to it, when it is safe to do so (see
      # #permissions_refusal). Returns the open file, or nil after closing it and recording why it is
      # refused, so that nothing is written to it.
      #
      # Changing the permissions of a file that another name links to could loosen them on an
      # unrelated file, such as a private key linked into a shared log directory. Writing log messages
      # to a file that this process does not own, or that another name links to, would let whoever
      # controls it read them, despite the permissions asked for. So with permissions, the appender
      # fails closed: it raises when it is created (see #initialize), and when the file is later
      # reopened, on a rotation, a fork, or a write retry, it stops writing and reports why (see
      # #refused) until the file is fixed (see #refused_retry_due?).
      def open_with_permissions(options)
        file   = ::File.open(current_file_name, options | SECURE_OPEN_FLAGS, permissions)
        reason = permissions_refusal(file)
        if reason
          close_quietly(file)
          return refuse(reason)
        end

        file.chmod(permissions)
        @refusal = @refusal_cause = @reported_refusal = nil
        file
      rescue SystemCallError => e
        close_quietly(file)
        refuse(open_refusal(e), e)
      end

      # Records why the log file is refused, and returns nil.
      def refuse(reason, cause = nil)
        @refusal          = reason
        @refusal_cause    = cause
        @refused_retry_at = monotonic_time + REFUSED_RETRY_INTERVAL
        nil
      end

      # Reports why log messages are not being written to the log file, once for each file and
      # reason, and returns false.
      def refused
        refusal = [current_file_name, @refusal]
        unless @reported_refusal == refusal
          @reported_refusal = refusal
          logger.error(refusal_message)
        end
        false
      end

      def refusal_message
        "Not writing to the log file #{current_file_name}: #{@refusal}"
      end

      # Returns why the log file could not be opened with permissions.
      def open_refusal(error)
        return "it is a symbolic link" if error.is_a?(Errno::ELOOP) && ::File.symlink?(current_file_name)

        "it could not be opened (#{error.message})"
      end

      # Returns why the permissions must not be applied to the open log file, nor log messages
      # written to it, or nil when they can.
      #
      # It must be a regular file owned by this process, with a single hard link, since a hard link
      # planted in the log directory is otherwise indistinguishable from the file it links to. The
      # path must also still name it, so that swapping the path after opening cannot redirect the
      # log messages.
      def permissions_refusal(file)
        stat      = file.stat
        path_stat = ::File.lstat(current_file_name)
        return "it is not a regular file" unless stat.file?
        return "it is not owned by this process" unless stat.uid == ::Process.euid
        return "it has more than one hard link" unless stat.nlink == 1
        return "it changed after it was opened" unless path_stat.dev == stat.dev && path_stat.ino == stat.ino

        nil
      rescue SystemCallError => e
        "it could not be checked (#{e.message})"
      end

      def close_quietly(file)
        file&.close
      rescue StandardError
        nil
      end

      def monotonic_time
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end

      def time_to_reopen?
        return refused_retry_due? unless @file

        (reopen_count.positive? && (log_count >= reopen_count)) ||
          (reopen_size.positive? && (log_size >= reopen_size)) ||
          (reopen_at && (Time.now > reopen_at))
      end

      # A refused log file is opened again every few seconds, and at the next scheduled reopen,
      # rather than for every message.
      def refused_retry_due?
        return true unless @refused_retry_at

        monotonic_time >= @refused_retry_at || (reopen_at && Time.now > reopen_at)
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
        unless duration
          raise(ArgumentError,
                "Invalid or missing duration in: #{period_string}, must begin with an integer.")
        end
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
