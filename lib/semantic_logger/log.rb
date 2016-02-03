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
    def each_exception
      # With thanks to https://github.com/bugsnag/bugsnag-ruby/blob/6348306e44323eee347896843d16c690cd7c4362/lib/bugsnag/notification.rb#L81
      depth      = 0
      exceptions = []
      ex         = exception
      while ex != nil && !exceptions.include?(ex) && exceptions.length < MAX_EXCEPTIONS_TO_UNWRAP
        exceptions << ex
        yield(ex, depth)

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
        "#{'%.3f' % seconds}s"
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
      file, line = file_name_and_line(true)
      file_name  = " #{file}:#{line}" if file

      "#{$$}:#{"%.#{thread_name_length}s" % thread_name}#{file_name}"
    end

    CALLER_REGEXP = /^(.*):(\d+).*/

    # Extract the filename and line number from the last entry in the supplied backtrace
    def extract_file_and_line(stack, short_name = false)
      match = CALLER_REGEXP.match(stack.first)
      [short_name ? File.basename(match[1]) : match[1], match[2].to_i]
    end

    # Returns [String, String] the file_name and line_number from the backtrace supplied
    # in either the backtrace or exception
    def file_name_and_line(short_name = false)
      if backtrace || (exception && exception.backtrace)
        stack = backtrace || exception.backtrace
        extract_file_and_line(stack, short_name) if stack && stack.size > 0
      end
    end

    # Strip the standard Rails colorizing from the logged message
    def cleansed_message
      message.to_s.gsub(/(\e(\[([\d;]*[mz]?))?)?/, '').strip
    end

    # Return the payload in text form
    # Returns nil if payload is missing or empty
    def payload_to_s(colorized = false)
      return if payload.nil? || (payload.respond_to?(:empty?) && payload.empty?)
      return payload.inspect if !colorized || !defined?(AwesomePrint) || !payload.respond_to?(:ai)

      # Colorize the payload if the AwesomePrint gem is loaded
      payload.ai(multiline: false) rescue payload.inspect
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
