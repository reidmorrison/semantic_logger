# Base appender
#
#   Abstract base class for appenders
#
#   Implements common behavior such as log level, default text formatter etc
#
#   Note: Do not create instances of this class directly
#
module SemanticLogger
  class Base
    attr_accessor :formatter
    attr_reader   :level

    def initialize(level, &block)
      # Set the formatter to the supplied block
      @formatter = block || default_formatter

      # Log everything that comes to the appender by default
      self.level = level || :trace
    end

    # Default log formatter
    #  Replace this formatter by supplying a Block to the initializer
    #  Generates logs of the form:
    #    2011-07-19 14:36:15.660 D [1149:ScriptThreadProcess] Rails -- Hello World
    def default_formatter
      Proc.new do |log|
        message = log.message.to_s
        tags = log.tags.collect { |tag| "[#{tag}]" }.join(" ") + " " if log.tags && (log.tags.size > 0)

        if log.payload
          if log.payload.is_a?(Exception)
            exception = log.payload
            message << " -- " << "#{exception.class}: #{exception.message}\n#{(exception.backtrace || []).join("\n")}"
          else
            message << " -- " << self.class.inspect_payload(log.payload)
          end
        end

        duration_str = log.duration ? "(#{'%.1f' % log.duration}ms) " : ''

        "#{SemanticLogger::Base.formatted_time(log.time)} #{log.level.to_s[0..0].upcase} [#{$$}:#{log.thread_name}] #{tags}#{duration_str}#{log.name} -- #{message}"
      end
    end

    # Write log data to underlying data storage
    def log(log_)
      raise "Logging Appender must implement #log(log)"
    end

    # Set the logging level for this appender
    #
    # Note: This level is only for this particular appender. It does not override
    #   the log level in any logging instance or the default log level
    #   SemanticLogger::Logger.level
    #
    # Must be one of the values in SemanticLogger::Logger::LEVELS
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
    # Example:
    #    require 'semantic_logger'
    #
    #    # Enable trace level logging
    #    SemanticLogger::Logger.level = :info
    #
    #    # Log to screen
    #    SemanticLogger::Logger.appenders << SemanticLogger::Appender::File.new(STDOUT)
    #
    #    # And log to a file at the same time
    #    SemanticLogger::Logger.appenders << SemanticLogger::Appender::File.new('application.log')
    #
    #    logger = SemanticLogger::Logger.new('MyApplication')
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
        def #{level}(message = nil, payload = nil)
          if @level_index <= #{index}
            if block_given? && (result = yield)
              if result.is_a?(String)
                message = message.nil? ? result : "\#{message} -- \#{result.to_s}"
              else
                payload = payload.nil? ? result : payload.merge(result)
              end
            end
            # Add scoped payload
            if self.payload
              payload = payload.nil? ? self.payload : self.payload.merge(payload)
            end
            log Log.new(:#{level}, self.class.thread_name, name, message, payload, Time.now, nil, tags, #{index})
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
          log_exception = params.nil? ? :full : params[:log_exception]
          min_duration  = params.nil? ? 0.0   : (params[:min_duration] || 0.0)
          payload       = params.nil? ? nil   : params[:payload]
          if @level_index <= #{index}
            start = Time.now
            begin
              result = yield
              end_time = Time.now
              duration = 1000.0 * (end_time - start)

              # Only log if the block took longer than 'min_duration' to complete
              if duration >= min_duration
                # Add scoped payload
                if self.payload
                  payload = payload.nil? ? self.payload : self.payload.merge(payload)
                end
                log Log.new(:#{level}, self.class.thread_name, name, message, payload, end_time, duration, tags, #{index})
              end
              result
            rescue Exception => exc
              if log_exception == :full
                log Log.new(:#{level}, self.class.thread_name, name, message, exc, Time.now, 1000.0 * (Time.now - start), tags, #{index})
              elsif log_exception == :partial
                log Log.new(:#{level}, self.class.thread_name, name, "\#{message} -- \#{exception.class}: \#{exception.message}", payload, end_time, 1000.0 * (end_time - start), tags, #{index})
              end
              raise exc
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
    def with_tags(*tags)
      current_tags = self.tags
      # Check for nil tags
      if tags
        Thread.current[:semantic_logger_tags] = current_tags ? current_tags + tags : tags
      end
      yield
    ensure
      Thread.current[:semantic_logger_tags] = current_tags
    end

    # Add support for the ActiveSupport::TaggedLogging
    alias_method :tagged, :with_tags

    # Returns [Array] of [String] tags currently active for this thread
    # Returns nil if no tags are set
    def tags
      Thread.current[:semantic_logger_tags]
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

    ############################################################################
    protected

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
    Log = Struct.new(:level, :thread_name, :name, :message, :payload, :time, :duration, :tags, :level_index)

    # For JRuby include the Thread name rather than its id
    if defined? Java
      # Name of the current Thread
      def self.thread_name
        Java::java.lang::Thread.current_thread.name
      end

      # Return the Time as a formatted string
      # JRuby only supports time in ms
      def self.formatted_time(time)
        "#{time.strftime("%Y-%m-%d %H:%M:%S")}.#{"%03d" % (time.usec/1000)}"
      end
    else
      def self.thread_name
        Thread.current.object_id
      end

      # Return the Time as a formatted string
      # Ruby MRI supports micro seconds
      def self.formatted_time(time)
        "#{time.strftime("%Y-%m-%d %H:%M:%S")}.#{"%06d" % (time.usec)}"
      end
    end

    if RUBY_VERSION.to_f >= 1.9
      # With Ruby 1.9 calling .to_s on a hash now returns { 'a' => 1 }
      def self.inspect_payload(payload)
        payload.to_s
      end
    else
      def self.inspect_payload(payload)
        payload.inspect
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

    # Appenders don't take a class name, so use this class name if an appender
    # is logged to directly
    def name
      self.class.name
    end

  end
end
