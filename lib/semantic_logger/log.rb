module SemanticLogger
  # Log Struct
  #
  #   Structure for holding all log entries
  #
  # level
  #   Log level of the supplied log call
  #   :trace, :debug, :info, :warn, :error, :fatal
  #
  # thread_name
  #   Name of the thread in which the logging call was called
  #
  # name
  #   Class name supplied to the logging instance
  #
  # message
  #   Text message to be logged
  #
  # payload
  #   Optional Hash or Ruby Exception object to be logged
  #
  # time
  #   The time at which the log entry was created
  #
  # duration
  #   The time taken to complete a benchmark call
  #
  # tags
  #   Any tags active on the thread when the log call was made
  #
  # level_index
  #   Internal index of the log level
  #
  # exception
  #   Ruby Exception object to log
  #
  # metric [Object]
  #   Object supplied when benchmark_x was called
  #
  # backtrace [Array<String>]
  #   The backtrace captured at source when the log level >= SemanticLogger.backtrace_level
  Log = Struct.new(:level, :thread_name, :name, :message, :payload, :time, :duration, :tags, :level_index, :exception, :metric, :backtrace) do

    MAX_EXCEPTIONS_TO_UNWRAP = 5
    # Call the block for exception and any nested exception
    def each_exception(&block)
      # With thanks to https://github.com/bugsnag/bugsnag-ruby/blob/6348306e44323eee347896843d16c690cd7c4362/lib/bugsnag/notification.rb#L81
      depth      = 0
      exceptions = []
      ex         = exception
      while ex != nil && !exceptions.include?(ex) && exceptions.length < MAX_EXCEPTIONS_TO_UNWRAP
        exceptions << ex
        block.call(ex, depth)

        depth += 1
        ex    =
          if ex.respond_to?(:cause) && ex.cause
            ex.cause
          elsif ex.respond_to?(:continued_exception) && ex.continued_exception
            ex.continued_exception
          elsif ex.respond_to?(:original_exception) && ex.original_exception
            ex.original_exception
          end
      end
    end

    # Returns [String] duration of the log entry as a string
    # Returns nil if their is no duration
    # Java time precision does not include microseconds
    if defined? JRuby
      def duration_to_s
        "#{duration.to_i}ms" if duration
      end
    else
      def duration_to_s
        return unless duration
        duration < 10.0 ? "#{'%.3f' % duration}ms" : "#{'%.1f' % duration}ms"
      end
    end

    # Returns [String] the duration in human readable form
    def duration_human
      return nil unless duration
      seconds = duration / 1000
      if seconds >= 86400.0 # 1 day
        "#{(seconds / 86400).to_i}d #{Time.at(seconds).strftime('%-Hh %-Mm')}"
      elsif seconds >= 3600.0 # 1 hour
        Time.at(seconds).strftime('%-Hh %-Mm')
      elsif seconds >= 60.0 # 1 minute
        Time.at(seconds).strftime('%-Mm %-Ss')
      elsif seconds >= 1.0 # 1 second
        Time.at(seconds).strftime('%-Ss %Lms')
      else
        duration_to_s
      end
    end

    # Returns [String] single character upper case log level
    def level_to_s
      level.to_s[0..0].upcase
    end

    # Returns [String] the available process info
    # Example:
    #    18934:thread 23 test_logging.rb:51
    def process_info(thread_name_length = 30)
      file, line = file_name_and_line
      file_name  = " #{file}:#{line}" if file

      "#{$$}:#{"%.#{thread_name_length}s" % thread_name}#{file_name}"
    end

    # Returns [String, String] the file_name and line_number from the backtrace supplied
    # in either the backtrace or exception
    def file_name_and_line
      if backtrace || (exception && exception.backtrace)
        stacktrace = backtrace || exception.backtrace
        stacktrace[0].split('/').last.split(':')[0..1] if stacktrace && stacktrace.size > 0
      end
    end

    # Strip the standard Rails colorizing from the logged message
    def cleansed_message
      message.to_s.gsub(/(\e(\[([\d;]*[mz]?))?)?/, '').strip
    end

    if defined? JRuby
      # Return the Time as a formatted string
      # JRuby only supports time in ms
      def formatted_time
        "#{time.strftime('%Y-%m-%d %H:%M:%S')}.#{'%03d' % (time.usec/1000)}"
      end
    else
      # Return the Time as a formatted string
      # Ruby MRI supports micro seconds
      def formatted_time
        "#{time.strftime('%Y-%m-%d %H:%M:%S')}.#{'%06d' % (time.usec)}"
      end
    end

  end

end
