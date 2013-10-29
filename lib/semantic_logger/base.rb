# Base logger
#
#   Abstract base class for loggers
#
#   Implements common behavior such as log level, default text formatter etc
#
#   Note: Do not create instances of this class directly
#
module SemanticLogger
  class Base
    # Class name to be logged
    attr_accessor :name

    attr_reader :level

    # Set the logging level for this logger
    #
    # Note: This level is only for this particular appender. It does not override
    #   the log level in any logging instance or the default log level
    #   SemanticLogger.default_level
    #
    # Must be one of the values in SemanticLogger::LEVELS
    def level=(level)
      @level_index = self.class.map_level_to_index(level)
      @level = level
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
    #    SemanticLogger.add_appender(STDOUT)
    #
    #    # And log to a file at the same time
    #    SemanticLogger.add_appender('application.log')
    #
    #    logger = SemanticLogger['MyApplication']
    #    logger.debug("Only display this if log level is set to Debug or lower")
    #
    #    # Log semantic information along with a text message
    #    logger.info("Request received", :user => "joe", :duration => 100)
    #
    #    # Log an exception in a semantic way
    #    logger.info("Parsing received XML", exc)
    #
    SemanticLogger::LEVELS.each_with_index do |level, index|
      class_eval <<-EOT, __FILE__, __LINE__
        def #{level}(message=nil, payload=nil, exception=nil)
          if @level_index <= #{index}
            if exception.nil? && payload && payload.is_a?(Exception)
              exception = payload
              payload = nil
            end

            if block_given? && (result = yield)
              if result.is_a?(String)
                message = message.nil? ? result : "\#{message} -- \#{result}"
              elsif payload && payload.respond_to?(:merge)
                payload.merge(result)
              else
                payload = result
              end
            end

            # Add scoped payload
            if self.payload
              payload = payload.nil? ? self.payload : self.payload.merge(payload)
            end
            log Log.new(:#{level}, self.class.thread_name, name, message, payload, Time.now, nil, tags, #{index}, exception)
            true
          else
            false
          end
        end

        def #{level}?
          @level_index <= #{index}
        end

        def benchmark_#{level}(message, params = nil)
          raise "Mandatory block missing" unless block_given?
          if @level_index <= #{index}
            log_exception = params.nil? ? :partial : (params[:log_exception] || :partial)
            min_duration  = params.nil? ? 0.0      : (params[:min_duration] || 0.0)
            payload       = params.nil? ? nil      : params[:payload]
            exception     = params.nil? ? nil      : params[:exception]
            start         = Time.now
            begin
              yield
            rescue Exception => exc
              exception = exc
            ensure
              end_time = Time.now
              duration = 1000.0 * (end_time - start)

              # Add scoped payload
              if self.payload
                payload = payload.nil? ? self.payload : self.payload.merge(payload)
              end
              if exception
                case log_exception
                when :full
                  log Log.new(:#{level}, self.class.thread_name, name, message, payload, end_time, duration, tags, #{index}, exception)
                when :partial
                  log Log.new(:#{level}, self.class.thread_name, name, "\#{message} -- Exception: \#{exception.class}: \#{exception.message}", payload, end_time, duration, tags, #{index}, nil)
                end
                raise exception
              elsif duration >= min_duration
                # Only log if the block took longer than 'min_duration' to complete
                log Log.new(:#{level}, self.class.thread_name, name, message, payload, end_time, duration, tags, #{index}, nil)
              end
            end
          else
            yield
          end
        end
      EOT
    end

    # Add the supplied tags to the list of tags to log for this thread whilst
    # the supplied block is active
    # Returns nil if no tags are currently set
    #   To support: ActiveSupport::TaggedLogging V3 and above
    def tagged(*tags)
      push_tags(*tags)
      yield
    ensure
      pop_tags(tags.size)
    end

    # Previous method for supplying tags
    alias_method :with_tags, :tagged

    # Returns [Array] of [String] tags currently active for this thread
    # Returns nil if no tags are set
    def tags
      Thread.current[:semantic_logger_tags] ||= []
    end

    # Add tags to the current scope
    #   To support: ActiveSupport::TaggedLogging V4 and above
    def push_tags *tags
      # Check for nil tags
      Thread.current[:semantic_logger_tags] = self.tags.concat(tags)
    end

    # Remove specified number of tags from the current tag list
    #   To support: ActiveSupport::TaggedLogging V4 and above
    def pop_tags(quantity=1)
      tags.pop(quantity)
    end

    # Thread specific context information to be logged with every log entry
    #
    # Add a payload to all log calls on This Thread within the supplied block
    #
    #   logger.with_payload(:tracking_number=>12345) do
    #     logger.debug('Hello World')
    #   end
    #
    # If a log call already includes a pyload, this payload will be merged with
    # the supplied payload, with the supplied payload taking precedence
    #
    #   logger.with_payload(:tracking_number=>12345) do
    #     logger.debug('Hello World', :result => 'blah')
    #   end
    def with_payload(payload)
      current_payload = self.payload
      Thread.current[:semantic_logger_payload] = current_payload ? current_payload.merge(payload) : payload
      yield
    ensure
      Thread.current[:semantic_logger_payload] = current_payload
    end

    # Returns [Hash] payload to be added to every log entry in the current scope
    # on this thread.
    # Returns nil if no payload is currently set
    def payload
      Thread.current[:semantic_logger_payload]
    end

    # Semantic Logging does not support :unknown level since these
    # are not understood by the majority of the logging providers
    # Map it to :error
    alias :unknown :error
    alias :unknown? :error?

    # #TODO implement a thread safe #silence method

    # DEPRECATED See SemanticLogger.default_level=
    def self.default_level=(level)
      warn "[DEPRECATION] `SemanticLogger::Logger.default_level=` is deprecated.  Please use `SemanticLogger.default_level=` instead."
      SemanticLogger.default_level = level
    end

    # DEPRECATED See SemanticLogger.default_level
    def self.default_level
      warn "[DEPRECATION] `SemanticLogger::Logger.default_level` is deprecated.  Please use `SemanticLogger.default_level` instead."
      SemanticLogger.default_level
    end

    ############################################################################
    protected

    def initialize(klass, level=nil)
      @name = klass.is_a?(String) ? klass : klass.name
      self.level = level || SemanticLogger.default_level
    end

    # Write log data to underlying data storage
    def log(log_)
      raise NotImplementedError.new("Logging Appender must implement #log(log)")
    end

    # Return the level index for fast comparisons
    attr_reader :level_index

    # Struct Log
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
    Log = Struct.new(:level, :thread_name, :name, :message, :payload, :time, :duration, :tags, :level_index, :exception)

    # For JRuby include the Thread name rather than its id
    if defined? Java
      # Name of the current Thread
      def self.thread_name
        Java::java.lang::Thread.current_thread.name
      end
    else
      def self.thread_name
        Thread.current.object_id
      end
    end

    # Internal method to return the log level as an internal index
    # Also supports mapping the ::Logger levels to SemanticLogger levels
    def self.map_level_to_index(level)
      index = if level.is_a?(Integer) && defined?(::Logger::Severity)
        # Mapping of Rails and Ruby Logger levels to SemanticLogger levels
        @@map_levels ||= begin
          levels = []
          ::Logger::Severity.constants.each do |constant|
            levels[::Logger::Severity.const_get(constant)] = LEVELS.find_index(constant.downcase.to_sym) || LEVELS.find_index(:error)
          end
          levels
        end
        @@map_levels[level]
      elsif level.is_a?(String)
        level = level.downcase.to_sym
        LEVELS.index(level)
      else
        LEVELS.index(level)
      end
      raise "Invalid level:#{level.inspect} being requested. Must be one of #{LEVELS.inspect}" unless index
      index
    end

  end
end
