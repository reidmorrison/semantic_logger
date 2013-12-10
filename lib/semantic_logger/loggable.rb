require 'sync_attr'

# Logger class variable mix-in
#
#   Lazy initialize a logger class variable with instance accessor
#
#   By including this mix-in into any class it will define a class level logger
#   and also make it accessible via instance methods
#
# Example
#
#  require 'semantic_logger'
#  SemanticLogger.default_level = :debug
#  SemanticLogger.add_appender(STDOUT)
#
#  class ExternalSupplier
#    # Create class and instance logger methods
#    include SemanticLogger::Loggable
#
#    def call_supplier(amount, name)
#      logger.debug "Calculating with amount", { :amount => amount, :name => name }
#
#      # Measure and log on completion how long the call took to the external supplier
#      logger.benchmark_info "Calling external interface" do
#        # Code to call the external supplier ...
#      end
#    end
#  end
module SemanticLogger
  module Loggable

    def self.included(base)
      base.class_eval do
        # Thread safe class variable initialization
        include SyncAttr

        sync_cattr_reader :logger do
          SemanticLogger[self]
        end
      end
    end

    # Also make the logger available as an instance method MixIn
    # The class logger can be replaced using an instance specific #logger= below
    def logger
      @semantic_logger ||= self.class.logger
    end

    # Set instance specific logger
    #
    # By default instances of the class will use the class logger. Sometimes it
    # is useful to be able to add instance specific logging data to the class name.
    #
    # For example, server or host_name that the class instance is using.
    #
    # Example:
    #   require 'semantic_logger'
    #   SemanticLogger.default_level = :debug
    #   SemanticLogger.add_appender(STDOUT)
    #
    #   class MyClass
    #     include SemanticLogger::Loggable
    #
    #     def self.my_name=(my_name)
    #       # Use class level logger that only logs class name
    #       logger.info "My name is changed to #{my_name}"
    #
    #       @@my_name = my_name
    #     end
    #
    #     def initialize(host_name)
    #       # Add host_name to every log entry in this logging instance
    #       self.logger = SemanticLogger["#{self.class.name} [#{host_name}]"]
    #
    #       logger.info "Started server"
    #     end
    #
    #     def check
    #       logger.debug "Checking..."
    #     end
    #   end
    #
    #   MyClass.my_name = "Joe"
    #
    #   mine = MyClass.new('server.com')
    #   mine.check
    #
    # # Generates the following log output:
    #
    # 2013-04-02 15:08:42.368574 I [37279:70198560687720] MyClass -- My name is changed to Joe
    # 2013-04-02 15:08:42.369934 I [37279:70198560687720] MyClass [server.com] -- Started server
    # 2013-04-02 15:08:42.371171 D [37279:70198560687720] MyClass [server.com] -- Checking...
    #
    def logger=(logger)
      @semantic_logger = logger
    end

  end
end