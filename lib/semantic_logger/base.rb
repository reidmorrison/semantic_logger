# Base logger
#
#   Abstract base class for loggers
#
#   Implements common behavior such as log level, default text formatter etc
#
module SemanticLogger
  class Base
    # Class name to be logged
    attr_accessor :name, :filter

    # Set the logging level for this logger
    #
    # Note: This level is only for this particular instance. It does not override
    #   the log level in any logging instance or the default log level
    #   SemanticLogger.default_level
    #
    # Must be one of the values in SemanticLogger::LEVELS, or
    # nil if this logger instance should use the global default level
    def level=(level)
      if level.nil?
        # Use the global default level for this logger
        @level_index = nil
        @level       = nil
      else
        @level_index = Levels.index(level)
        @level       = Levels.level(@level_index)
      end
    end

    # Returns the current log level if set, otherwise it returns the global
    # default log level
    def level
      @level || SemanticLogger.default_level
    end

    # Implement the log level calls
    #   logger.debug(message, hash|exception=nil, &block)
    #
    # Implement the log level query
    #   logger.debug?
    #
    # Parameters:
    #   message
    #     [String] text message to be logged
    #     Should always be supplied unless the result of the supplied block returns
    #     a string in which case it will become the logged message
    #     Default: nil
    #
    #   payload
    #     [Hash|Exception] Optional hash payload or an exception to be logged
    #     Default: nil
    #
    #   exception
    #     [Exception] Optional exception to be logged
    #     Allows both an exception and a payload to be logged
    #     Default: nil
    #
    # Examples:
    #    require 'semantic_logger'
    #
    #    # Enable trace level logging
    #    SemanticLogger.default_level = :info
    #
    #    # Log to screen
    #    SemanticLogger.add_appender(io: $stdout, formatter: :color)
    #
    #    # And log to a file at the same time
    #    SemanticLogger.add_appender(file_name: 'application.log', formatter: :color)
    #
    #    logger = SemanticLogger['MyApplication']
    #    logger.debug("Only display this if log level is set to Debug or lower")
    #
    #    # Log semantic information along with a text message
    #    logger.info("Request received", user: "joe", duration: 100)
    #
    #    # Log an exception in a semantic way
    #    logger.info("Parsing received XML", exc)
    #
    SemanticLogger::Levels::LEVELS.each_with_index do |level, index|
      class_eval <<~METHODS, __FILE__, __LINE__ + 1
        def #{level}(message=nil, payload=nil, exception=nil, &block)
          if level_index <= #{index}
            log_internal(:#{level}, #{index}, message, payload, exception, &block)
            true
          else
            false
          end
        end

        def #{level}?
          level_index <= #{index}
        end

        def measure_#{level}(message, params = {}, &block)
          if level_index <= #{index}
            measure_internal(:#{level}, #{index}, message, params, &block)
          else
            block.call(params) if block
          end
        end

        def benchmark_#{level}(message, params = {}, &block)
          if level_index <= #{index}
            measure_internal(:#{level}, #{index}, message, params, &block)
          else
            block.call(params) if block
          end
        end
      METHODS
    end

    # Dynamically supply the log level with every measurement call
    def measure(level, message, params = {}, &block)
      index = Levels.index(level)
      if level_index <= index
        measure_internal(level, index, message, params, &block)
      elsif block
        yield(params)
      end
    end

    # Backward compatibility
    alias benchmark measure

    # Log a thread backtrace
    def backtrace(thread: Thread.current,
                  level: :warn,
                  message: "Backtrace:",
                  payload: nil,
                  metric: nil,
                  metric_amount: nil)

      log = Log.new(name, level)
      return false unless meets_log_level?(log)

      backtrace =
        if thread == Thread.current
          Utils.extract_backtrace(caller)
        else
          log.thread_name = thread.name
          log.tags        = (thread[:semantic_logger_tags] || []).clone
          log.named_tags  = (thread[:semantic_logger_named_tags] || {}).clone
          thread.backtrace
        end
      # TODO: Keep backtrace instead of transforming into a text message at this point
      # Maybe log_backtrace: true
      if backtrace
        message += "\n"
        message << backtrace.join("\n")
      end

      if log.assign(message:       message,
                    backtrace:     backtrace,
                    payload:       payload,
                    metric:        metric,
                    metric_amount: metric_amount) && !filtered?(log)
        self.log(log)
      else
        false
      end
    end

    # Add the tags or named tags to the list of tags to log for this thread whilst the supplied block is active.
    #
    # Returns result of block.
    #
    # Tagged example:
    #   SemanticLogger.tagged(12345, 'jack') do
    #     logger.debug('Hello World')
    #   end
    #
    # Named Tags (Hash) example:
    #   SemanticLogger.tagged(tracking_number: 12345) do
    #     logger.debug('Hello World')
    #   end
    #
    # Notes:
    # - Named tags are the recommended approach since the tag consists of a name value pair this is more useful
    #   than just a string value in the logs, or centralized logging system.
    # - This method is slow when using multiple text tags since it needs to flatten the tags and
    #   remove empty elements to support Rails 4.
    # - It is recommended to keep tags as a list without any empty values, or contain any child arrays.
    #   However, this api will convert:
    #     `logger.tagged([['first', nil], nil, ['more'], 'other'])`
    #   to:
    #     `logger.tagged('first', 'more', 'other')`
    # - For better performance with clean tags, see `SemanticLogger.tagged`.
    def tagged(*tags)
      block = -> { yield(self) }
      # Allow named tags to be passed into the logger
      # Rails::Rack::Logger passes logs as an array with a single argument
      if tags.size == 1 && !tags.first.is_a?(Array)
        tag = tags[0]
        return yield if tag.nil? || tag == ""

        return tag.is_a?(Hash) ? SemanticLogger.named_tagged(tag, &block) : SemanticLogger.fast_tag(tag.to_s, &block)
      end

      # Need to flatten and reject empties to support calls from Rails 4
      new_tags = tags.flatten.collect(&:to_s).reject(&:empty?)
      SemanticLogger.tagged(*new_tags, &block)
    end

    # :nodoc:
    alias with_tags tagged

    # :nodoc:
    def tags
      SemanticLogger.tags
    end

    def named_tags
      SemanticLogger.named_tags
    end

    # Returns the list of tags pushed after flattening them out and removing blanks
    #
    # Note:
    # - This method is slow since it needs to flatten the tags and remove empty elements
    #   to support Rails 4.
    # - For better performance with clean tags, use `SemanticLogger.push_tags`
    def push_tags(*tags)
      # Need to flatten and reject empties to support calls from Rails 4
      new_tags = tags.flatten.collect(&:to_s).reject(&:empty?)
      SemanticLogger.push_tags(*new_tags)
    end

    # :nodoc:
    def pop_tags(quantity = 1)
      SemanticLogger.pop_tags(quantity)
    end

    # :nodoc:
    def silence(new_level = :error, &block)
      SemanticLogger.silence(new_level, &block)
    end

    # :nodoc:
    def fast_tag(tag, &block)
      SemanticLogger.fast_tag(tag, &block)
    end

    # Write log data to underlying data storage
    def log(_log_)
      raise NotImplementedError, "Logging Appender must implement #log(log)"
    end

    # Whether this log entry meets the criteria to be logged by this appender.
    def should_log?(log)
      meets_log_level?(log) && !filtered?(log)
    end

    private

    # Initializer for Abstract Class SemanticLogger::Base
    #
    # Parameters
    #  klass [String]
    #   Name of the class, module, or other identifier for which the log messages
    #   are being logged
    #
    #  level [Symbol]
    #    Only allow log entries of this level or higher to be written to this appender
    #    For example if set to :warn, this appender would only log :warn and :fatal
    #    log messages when other appenders could be logging :info and lower
    #
    #  filter [Regexp|Proc|Module]
    #    RegExp: Only include log messages where the class name matches the supplied
    #    regular expression. All other messages will be ignored
    #    Proc: Only include log messages where the supplied Proc returns true
    #          The Proc must return true or false
    #    Module: A module that implements `.call`. For example:
    #      module ComplexFilter
    #        def self.call(log)
    #          (/\AExclude/ =~ log.message).nil?
    #        end
    #      end
    def initialize(klass, level = nil, filter = nil)
      # Support filtering all messages to this logger instance.
      unless filter.nil? || filter.is_a?(Regexp) || filter.is_a?(Proc) || filter.respond_to?(:call)
        raise ":filter must be a Regexp, Proc, or implement :call"
      end

      @filter = filter.is_a?(Regexp) ? filter.freeze : filter
      @name   = klass.is_a?(String) ? klass : klass.name
      if level.nil?
        # Allow the global default level to determine this loggers log level
        @level_index = nil
        @level       = nil
      else
        self.level = level
      end
    end

    # Return the level index for fast comparisons
    # Returns the global default level index if the level has not been explicitly
    # set for this instance
    def level_index
      @level_index || SemanticLogger.default_level_index
    end

    # Whether to log the supplied message based on the current filter if any
    def filtered?(log)
      return false if @filter.nil?

      @filter.is_a?(Regexp) ? (@filter =~ log.name).nil? : @filter.call(log) != true
    end

    # Ensure minimum log level is met
    def meets_log_level?(log)
      (level_index <= (log.level_index || 0))
    end

    # Log message at the specified level
    def log_internal(level, index, message = nil, payload = nil, exception = nil)
      # Handle variable number of arguments by detecting exception object and payload hash.
      if exception.nil? && payload.nil? && message.respond_to?(:backtrace) && message.respond_to?(:message)
        exception = message
        message   = nil
      elsif exception.nil? && payload && payload.respond_to?(:backtrace) && payload.respond_to?(:message)
        exception = payload
        payload   = nil
      elsif payload && !payload.is_a?(Hash)
        message = message.nil? ? payload : "#{message} -- #{payload}"
        payload = nil
      end

      log = Log.new(name, level, index)
      should_log =
        if exception.nil? && payload.nil? && message.is_a?(Hash)
          # All arguments as a hash in the message.
          log.assign(**log.extract_arguments(message))
        elsif exception.nil? && message && payload && payload.is_a?(Hash)
          # Message supplied along with a hash with the remaining arguments.
          log.assign(**log.extract_arguments(payload, message))
        else
          # All fields supplied directly.
          log.assign(message: message, payload: payload, exception: exception)
        end

      # Add result of block to message or payload if not nil
      if block_given?
        result = yield(log)
        case result
        when String
          log.message = log.message.nil? ? result : "#{log.message} -- #{result}"
        when Hash
          log.assign_hash(result)
        end
      end

      # Log level may change during assign due to :on_exception_level
      self.log(log) if should_log && should_log?(log)
    end

    # Measure the supplied block and log the message
    def measure_internal(level, index, message, params)
      exception = nil
      result    = nil
      # Single parameter is a hash
      if params.empty? && message.is_a?(Hash)
        params  = message
        message = nil
      end
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        if block_given?
          result =
            if (silence_level = params[:silence])
              # In case someone accidentally sets `silence: true` instead of `silence: :error`
              silence_level = :error if silence_level == true
              silence(silence_level) { yield(params) }
            else
              yield(params)
            end
        end
      rescue Exception => e
        exception = e
      ensure
        # Must use ensure block otherwise a `return` in the yield above will skip the log entry
        log = Log.new(name, level, index)
        exception ||= params[:exception]
        message   = params[:message] if params[:message]
        duration  =
          if block_given?
            1_000.0 * (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start)
          else
            params[:duration] || raise("Mandatory block missing when :duration option is not supplied")
          end

        # Extract options after block completes so that block can modify any of the options
        payload = params[:payload]

        # May return false due to elastic logging
        should_log = log.assign(
          message:            message,
          payload:            payload,
          min_duration:       params[:min_duration] || 0.0,
          exception:          exception,
          metric:             params[:metric],
          metric_amount:      params[:metric_amount],
          duration:           duration,
          log_exception:      params[:log_exception] || :partial,
          on_exception_level: params[:on_exception_level]
        )

        # Log level may change during assign due to :on_exception_level
        self.log(log) if should_log && should_log?(log)
        raise exception if exception

        result
      end
    end

    # For measuring methods and logging their duration.
    def measure_method(index:,
                       level:,
                       message:,
                       min_duration:,
                       metric:,
                       log_exception:,
                       on_exception_level:)

      # Ignores filter, silence, payload
      exception = nil
      start     = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        yield
      rescue Exception => e
        exception = e
      ensure
        log = Log.new(name, level, index)
        # May return false due to elastic logging
        should_log = log.assign(
          message:            message,
          min_duration:       min_duration,
          exception:          exception,
          metric:             metric,
          duration:           1_000.0 * (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start),
          log_exception:      log_exception,
          on_exception_level: on_exception_level
        )

        # Log level may change during assign due to :on_exception_level
        log(log) if should_log && should_log?(log)
        raise exception if exception
      end
    end
  end
end
