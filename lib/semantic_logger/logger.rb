# Logger is the interface used by
#
# Logger maintains the logging name to be used for all log entries generated
# by the invoking classes or modules
#
# It is recommended to create an instance of the class for every class or
# module so that it can be uniquely identified and searched on
#
# Example, log to Logger:
#   require 'logger'
#   require 'semantic_logger'
#   log = Logger.new(STDOUT)
#   log.level = Logger::DEBUG
#
#   SemanticLogger::Manager.register_appender(SemanticLogger::Appender::Logger.new(log))
#
#   logger = SemanticLogger::Logger.new("my.app.class")
#   logger.debug("Login time", :user => 'Joe', :duration => 100, :ip_address=>'127.0.0.1')
#
# # Now log to the Logger above as well as Mongo at the same time
#
#   SemanticLogger::Manager.register_appender(SemanticLogger::Appender::Mongo.new(cfg))
# ...
#   logger.debug("Login time", :user => 'Mary', :duration => 230, :ip_address=>'192.168.0.1')
module SemanticLogger
  class Logger
    include SyncAttr

    # Logging levels in order of precendence
    LEVELS = [:trace, :debug, :info, :warn, :error]

    # Mapping of Rails and Ruby Logger levels to SemanticLogger levels
    MAP_LEVELS = []
    ::Logger::Severity.constants.each do |constant|
      MAP_LEVELS[::Logger::Severity.const_get(constant)] = LEVELS.find_index(constant.downcase.to_sym) || LEVELS.find_index(:error)
    end

    # Thread safe Class Attribute accessor for appenders array
    sync_cattr_accessor :appenders do
      []
    end

    # Allow for setting the default log level
    def self.default_level=(default_level)
      @@default_level = default_level
    end

    def self.default_level
      @@default_level
    end

    attr_reader :application, :level

    @@default_level = :info

    # Create a Logger instance
    # Parameters:
    #  application: A class, module or a string with the application/class name
    #               to be used in the logger
    #  options:
    #    :level   The initial log level to start with for this logger instance
    def initialize(application, options={})
      @application = application.is_a?(String) ? application : application.name
      set_level(options[:level] || self.class.default_level)
    end

    # Set the logging level
    # Must be one of the values in #LEVELS
    def level=(level)
      set_level(level)
    end

    # Implement the log level calls
    #   logger.debug(message|hash|exception, hash|exception=nil, &block)
    #
    # Implement the log level query
    #   logger.debug?
    #
    # Example:
    #   logger = SemanticLogging::Logger.new('MyApplication')
    #   logger.debug("Only display this if log level is set to Debug or lower")
    #
    #   # Log semantic information along with a text message
    #   logger.info("Request received", :user => "joe", :duration => 100)
    #
    #   # Log an exception in a semantic way
    #   logger.info("Parsing received XML", exc)
    #
    LEVELS.each_with_index do |level, index|
      class_eval <<-EOT, __FILE__, __LINE__
        def #{level}(message = nil, data = nil, &block)                                                          # def trace(message = nil, data = nil, &block)
          if @level_index <= #{index}                                                                            #   if @level_index <= 0
            self.class.appenders.each {|appender| appender.log(:#{level}, application, message, data, &block) }  #     self.class.appenders.each {|appender| appender.log(:trace, application, message, data, &block) }
            true                                                                                                 #     true
          else                                                                                                   #   else
            false                                                                                                #     false
          end                                                                                                    #   end
        end                                                                                                      # end

        def #{level}?                                                                                            # def trace?
          @level_index <= #{index}                                                                               #   @level_index <= 0
        end                                                                                                      # end
      EOT
    end

    # Semantic Logging does not support :fatal or :unknown levels since these
    # are not understood by the majority of the logging providers
    # Map them to :error
    alias :fatal :error
    alias :fatal? :error?
    alias :unknown :error
    alias :unknown? :error?

    # forward other calls to ActiveResource::BufferedLogger
    # #silence is not implemented since it is not thread safe prior to Rails 3.2
    # #TODO implement a thread safe silence method

    protected

    # Verify and set the level
    def set_level(level)
      index = if level.is_a?(Integer)
        MAP_LEVELS[level]
      elsif level.is_a?(String)
        level = level.downcase.to_sym
        LEVELS.index(level)
      else
        LEVELS.index(level)
      end

      raise "Invalid level:#{level.inspect} being requested. Must be one of #{LEVELS.inspect}" unless index
      @level_index = index
      @level = level
    end
  end
end