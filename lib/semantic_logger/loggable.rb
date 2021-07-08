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
#
# Notes:
# * To forcibly replace Rails or any other existing logging methods
#   use `prepend` instead of `include`. For example:
#     ExternalSupplier.prepend SemanticLogger::Loggable
module SemanticLogger
  module Loggable
    def self.included(base)
      base.extend ClassMethods
      base.singleton_class.class_eval do
        undef_method :logger if method_defined?(:logger)
        undef_method :logger= if method_defined?(:logger=)
      end
      base.class_eval do
        undef_method :logger if method_defined?(:logger)
        undef_method :logger= if method_defined?(:logger=)

        # Returns [SemanticLogger::Logger] class level logger
        def self.logger
          @semantic_logger ||= SemanticLogger[self]
        end

        # Replace instance class level logger
        def self.logger=(logger)
          @semantic_logger = logger
        end

        # Returns [SemanticLogger::Logger] instance level logger
        def logger
          @semantic_logger ||= self.class.logger
        end

        # Replace instance level logger
        def logger=(logger)
          @semantic_logger = logger
        end
      end
    end

    module ClassMethods
      # Measure and log the performance of an instance method.
      #
      # Parameters:
      #   method_name: [Symbol]
      #     The name of the method that should be measured.
      #
      #   options: [Hash]
      #     Any valid options that can be passed to measure.
      #
      # Approximate overhead when logging a method call with a metric:
      #   0.044 ms  per method call.
      #   0.009 ms  per method call. If `min_duration` is not met
      #   0.0005 ms per method call. If `level` is not met
      def logger_measure_method(method_name,
                                min_duration: 0.0,
                                metric: "#{name}/#{method_name}",
                                log_exception: :partial,
                                on_exception_level: nil,
                                message: "##{method_name}",
                                level: :info)

        # unless visibility = Utils.method_visibility(self, method_name)
        #   logger.warn("Unable to measure method: #{name}##{method_name} since it does not exist")
        #   return false
        # end

        index = Levels.index(level)

        logger_measure_module.module_eval(<<~MEASURE_METHOD, __FILE__, __LINE__ + 1)
          def #{method_name}(*args, &block)
            if logger.send(:level_index) <= #{index}
              logger.send(
                :measure_method,
                index:              #{index},
                level:              #{level.inspect},
                message:            #{message.inspect},
                min_duration:       #{min_duration},
                metric:             #{metric.inspect},
                log_exception:      #{log_exception.inspect},
                on_exception_level: #{on_exception_level.inspect}
              ) do
                super(*args, &block)
              end
            else
              super(*args, &block)
            end
          end
        MEASURE_METHOD
        # {"#{visibility} :#{method_name}" unless visibility == :public}
        true
      end

      private

      # Dynamic Module to intercept method calls for measuring purposes.
      def logger_measure_module
        if const_defined?(:SemanticLoggerMeasure, _search_ancestors = false)
          const_get(:SemanticLoggerMeasure)
        else
          mod = const_set(:SemanticLoggerMeasure, Module.new)
          prepend mod
          mod
        end
      end
    end
  end
end
