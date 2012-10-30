# Logger class variable mix-in
#
#   Lazy initialize and a logger class variable with instance accessor
#
#   By including this mix-in into any class it will define a class level logger
#   and make it accessible via instance methods
#
# Example
#
#  require 'semantic_logger'
#
#  class ExternalSupplier
#    # Lazy load 'logger' class variable on first use
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
          SemanticLogger::Logger.new(self)
        end
      end
    end

    # Also make the logger available as an instance method MixIn
    def logger
      self.class.logger
    end

  end
end