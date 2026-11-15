# Logger class variable mix-in
#
#   Lazy initialize a logger class variable with instance accessor
#
#   By including this mix-in into any class it will define a class level logger
#   and also make it accessible via instance methods
#
# Example:
#   require 'semantic_logger'
#   SemanticLogger.default_level = :debug
#   SemanticLogger.add_appender(io: $stdout, formatter: :color)
#
#   class ExternalSupplier
#     # Create class and instance logger methods
#     include SemanticLogger::Loggable
#
#     def call_supplier(amount, name)
#       logger.debug "Calculating with amount", { amount: amount, name: name }
#
#       # Measure and log on completion how long the call took to the external supplier
#       logger.measure_info "Calling external interface" do
#         # Code to call the external supplier ...
#       end
#     end
#   end
module SemanticLogger
  module Loggable
    def self.included(base)
      base.singleton_class.class_eval do
        undef_method :logger if method_defined?(:logger)
        undef_method :logger= if method_defined?(:logger=)
      end
      base.class_eval do
        undef_method :logger if method_defined?(:logger)
        undef_method :logger= if method_defined?(:logger=)

        # Returns [SemanticLogger::Logger] class level logger
        def self.logger
          return Loggable.ractor_loggers[self] ||= SemanticLogger[self] if RactorSupport.other_ractor?

          @semantic_logger ||= SemanticLogger[self]
        end

        # Replace instance class level logger
        def self.logger=(logger)
          if RactorSupport.other_ractor?
            Loggable.ractor_loggers[self] = logger
          else
            @semantic_logger = logger
          end
        end
      end

      if base.is_a?(Class)
        base.class_eval do
          # Returns [SemanticLogger::Logger] instance level logger
          def logger
            @semantic_logger ||= self.class.logger
          end

          # Replace instance level logger
          def logger=(logger)
            @semantic_logger = logger
          end
        end
      else
        base.class_eval do
          # Returns [SemanticLogger::Logger] instance level logger
          #
          # The module was included into, or extended, a class that need not include Loggable itself.
          def logger
            return Loggable.ractor_loggers[self] ||= Loggable.logger_for(self) if Loggable.ractor_owned?(self)

            @semantic_logger ||= Loggable.logger_for(self)
          end

          # Replace instance level logger
          def logger=(logger)
            if Loggable.ractor_owned?(self)
              Loggable.ractor_loggers[self] = logger
            else
              @semantic_logger = logger
            end
          end
        end
      end
    end

    # Returns [SemanticLogger::Logger] the logger for an object that uses a module that includes Loggable.
    #
    # A class or module that extended the module has a logger named after itself. An instance uses its
    # class's class level logger when it has one, otherwise one named after its class.
    def self.logger_for(object)
      return SemanticLogger[object] if object.is_a?(Module)

      klass = object.class
      klass.respond_to?(:logger) ? klass.logger : SemanticLogger[klass]
    end

    # Returns [true|false] whether the logger of the supplied object is held in the current Ractor
    # rather than by the object: a class or module, which a Ractor other than the main one cannot change.
    def self.ractor_owned?(object)
      object.is_a?(Module) && RactorSupport.other_ractor?
    end

    # Returns [Hash] the class level loggers of the current Ractor, when it is not the main one.
    #
    # A Ractor other than the main one cannot set, or use, the class level logger of the main Ractor,
    # which the class holds, so it has a logger of its own for each class (experimental, Ruby 4.0 and
    # later).
    def self.ractor_loggers
      ::Ractor.store_if_absent(:semantic_logger_loggable) { {} }
    end
  end
end
