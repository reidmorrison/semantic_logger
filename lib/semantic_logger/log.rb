module SemanticLogger
  # Log
  #
  #   Class to hold all log entry information
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
  #   The time taken to complete a measure call
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
  #   Object supplied when measure_x was called
  #
  # backtrace [Array<String>]
  #   The backtrace captured at source when the log level >= SemanticLogger.backtrace_level
  #
  # metric_amount [Numeric]
  #   Used for numeric or counter metrics.
  #   For example, the number of inquiries or, the amount purchased etc.
  #
  # context [Hash]
  #   Named contexts that were captured when the log entry was created.
  class Log
    # Keys passed in without a payload that will be extracted and the remainder passed into the payload.
    NON_PAYLOAD_KEYS = %i[message exception backtrace exception
                          duration min_duration
                          log_exception on_exception_level
                          metric metric_amount dimensions].freeze

    attr_accessor :level, :level_index, :name, :message, :time, :duration,
                  :payload, :exception, :thread_name, :backtrace,
                  :tags, :named_tags, :context,
                  :metric, :metric_amount, :dimensions

    def initialize(name, level, index = nil)
      @level       = level
      @thread_name = Thread.current.name
      @name        = name
      @time        = Time.now
      @tags        = SemanticLogger.tags
      @named_tags  = SemanticLogger.named_tags
      @level_index = index.nil? ? Levels.index(level) : index
    end

    # Assign named arguments to this log entry, supplying defaults where applicable
    #
    # Returns [true|false] whether this log entry should be logged
    #
    # Example:
    #   logger.info(name: 'value')
    def assign(message: nil,
               payload: nil,
               min_duration: 0.0,
               exception: nil,
               metric: nil,
               metric_amount: nil,
               duration: nil,
               backtrace: nil,
               log_exception: :full,
               on_exception_level: nil,
               dimensions: nil)

      self.message       = message
      self.payload       = payload
      self.duration      = duration
      self.metric        = metric
      self.metric_amount = metric_amount
      self.dimensions    = dimensions

      if exception
        case log_exception
        when :full
          self.exception = exception
        when :partial
          self.message = "#{message} -- Exception: #{exception.class}: #{exception.message}"
        when nil, :none
          # Log the message without the exception that was raised
          nil
        else
          raise(ArgumentError, "Invalid value:#{log_exception.inspect} for argument :log_exception")
        end
        # On exception change the log level
        if on_exception_level
          self.level       = on_exception_level
          self.level_index = Levels.index(level)
        end
      end

      # Elastic logging: Log when :duration exceeds :min_duration
      # Except if there is an exception when it will always be logged
      return false if duration && ((duration < min_duration) && exception.nil?)

      if backtrace
        self.backtrace = Utils.extract_backtrace(backtrace)
      elsif level_index >= SemanticLogger.backtrace_level_index
        self.backtrace = Utils.extract_backtrace(caller)
      end

      true
    end

    # Assign known keys to self, all other keys to the payload.
    def assign_hash(hash)
      self.payload ||= {}
      hash.each_pair do |key, value|
        if respond_to?("#{key}=".to_sym)
          public_send("#{key}=".to_sym, value)
        else
          payload[key] = value
        end
      end
      self.payload = nil if payload.empty?
      self
    end

    # Extract the arguments from a Hash Payload
    def extract_arguments(payload, message = nil)
      raise(ArgumentError, "payload must be a Hash") unless payload.is_a?(Hash)

      message = nil if message == ""
      if payload.key?(:payload)
        return message ? payload.merge(message: message) : payload
      end

      new_payload = {}
      args        = {}
      payload.each_pair do |key, value|
        # Supplied message takes precedence
        if (key == :message) && !message.nil?
          new_payload[key] = value
          next
        end

        NON_PAYLOAD_KEYS.include?(key) ? args[key] = value : new_payload[key] = value
      end
      args[:payload] = new_payload unless new_payload.empty?
      args[:message] = message if message
      args
    end

    MAX_EXCEPTIONS_TO_UNWRAP = 5
    # Call the block for exception and any nested exception
    def each_exception
      # With thanks to https://github.com/bugsnag/bugsnag-ruby/blob/6348306e44323eee347896843d16c690cd7c4362/lib/bugsnag/notification.rb#L81
      depth      = 0
      exceptions = []
      ex         = exception
      while !ex.nil? && !exceptions.include?(ex) && exceptions.length < MAX_EXCEPTIONS_TO_UNWRAP
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

    # Returns [String] the exception backtrace including all of the child / caused by exceptions
    def backtrace_to_s
      trace = ""
      each_exception do |exception, i|
        if i.zero?
          trace = (exception.backtrace || []).join("\n")
        else
          trace << "\nCause: #{exception.class.name}: #{exception.message}\n#{(exception.backtrace || []).join("\n")}"
        end
      end
      trace
    end

    # Returns [String] duration of the log entry as a string
    # Returns nil if their is no duration
    # Java time precision does not include microseconds
    if Formatters::Base::PRECISION == 3
      def duration_to_s
        "#{duration.to_i}ms" if duration
      end
    else
      def duration_to_s
        return unless duration

        duration < 10.0 ? "#{format('%.3f', duration)}ms" : "#{format('%.1f', duration)}ms"
      end
    end

    # Returns [String] the duration in human readable form
    def duration_human
      return nil unless duration

      seconds = duration / 1000
      if seconds >= 86_400.0 # 1 day
        "#{(seconds / 86_400).to_i}d #{Time.at(seconds).utc.strftime('%-Hh %-Mm')}"
      elsif seconds >= 3600.0 # 1 hour
        Time.at(seconds).utc.strftime("%-Hh %-Mm")
      elsif seconds >= 60.0 # 1 minute
        Time.at(seconds).utc.strftime("%-Mm %-Ss")
      elsif seconds >= 1.0 # 1 second
        "#{format('%.3f', seconds)}s"
      else
        duration_to_s
      end
    end

    # Returns [String] single character upper case log level
    def level_to_s
      level.to_s[0..0].upcase
    end

    # DEPRECATED
    def process_info(thread_name_length = 30)
      file, line = file_name_and_line(true)
      file_name  = " #{file}:#{line}" if file

      "#{$$}:#{format("%.#{thread_name_length}s", thread_name)}#{file_name}"
    end

    CALLER_REGEXP = /^(.*):(\d+).*/.freeze

    # Extract the filename and line number from the last entry in the supplied backtrace
    def extract_file_and_line(stack, short_name = false)
      return unless stack&.size&.positive?

      match = CALLER_REGEXP.match(stack.first)
      return unless match

      [short_name ? File.basename(match[1]) : match[1], match[2].to_i]
    end

    # Returns [String, String] the file_name and line_number from the backtrace supplied
    # in either the backtrace or exception
    def file_name_and_line(short_name = false)
      stack = backtrace || exception&.backtrace
      extract_file_and_line(stack, short_name)
    end

    # Strip the standard Rails colorizing from the logged message
    def cleansed_message
      message.to_s.gsub(/(\e(\[([\d;]*[mz]?))?)?/, "").strip
    end

    # Return the payload in text form
    # Returns nil if payload is missing or empty
    def payload_to_s
      payload.inspect if payload?
    end

    # Returns [true|false] whether the log entry has a payload
    def payload?
      !(payload.nil? || (payload.respond_to?(:empty?) && payload.empty?))
    end

    def to_h(host = SemanticLogger.host, application = SemanticLogger.application, environment = SemanticLogger.environment)
      logger = Struct.new(:host, :application, :environment).new(host, application, environment)
      SemanticLogger::Formatters::Raw.new.call(self, logger)
    end

    # Lazy initializes the context hash and assigns a key value pair.
    def set_context(key, value)
      (self.context ||= {})[key] = value
    end

    # A metric only event has a metric but no message or exception.
    def metric_only?
      metric && message.nil? && exception.nil?
    end
  end
end
