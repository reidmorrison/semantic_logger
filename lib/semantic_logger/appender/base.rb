# Base appender
#
#   Abstract base class for appenders
#
#   Implements common behavior such as default text formatter etc
#
#   Note: Do not create instances of this class directly
#
module SemanticLogger
  module Appender

    # DEPRECATED, use SemanticLogger::AnsiColors
    AnsiColors = SemanticLogger::AnsiColors

    class Base < SemanticLogger::Base
      # Every logger has its own formatter
      attr_accessor :formatter

      # Returns the current log level if set, otherwise it logs everything it receives
      def level
        @level || :trace
      end

      # An appender can implement a flush method if it is able to.
      def flush
        # NOOP
      end

      # DEPRECATED: use SemanticLogger::Formatters::Default.new
      def default_formatter
        warn '[DEPRECATION] SemanticLogger::Appender::Base.default_level is deprecated.  Please use SemanticLogger::Formatters::Default.new instead.'
        formatter = SemanticLogger::Formatters::Default.new
        Proc.new { |log, logger| formatter.call(log, logger) }
      end

      # DEPRECATED: use SemanticLogger::Formatters::Color.new
      def self.colorized_formatter
        warn '[DEPRECATION] SemanticLogger::Appender::Base.colorized_formatter is deprecated.  Please use SemanticLogger::Formatters::Color.new instead.'
        formatter = SemanticLogger::Formatters::Color.new
        Proc.new { |log, logger| formatter.call(log, logger) }
      end

      # DEPRECATED: use SemanticLogger::Formatters::Json.new
      def self.json_formatter
        warn '[DEPRECATION] SemanticLogger::Appender::Base.json_formatter is deprecated.  Please use SemanticLogger::Formatters::Json.new instead.'
        formatter = SemanticLogger::Formatters::Json.new
        Proc.new { |log, logger| formatter.call(log, logger) }
      end

      private

      # Initializer for Abstract Class SemanticLogger::Appender
      #
      # Parameters
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: :error
      #
      #   formatter: [Object|Proc]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: Use the built-in formatter (See: #call)
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      def initialize(options={}, &block)
        # Backward compatibility
        options    = {level: options} unless options.is_a?(Hash)
        options    = options.dup
        level      = options.delete(:level)
        filter     = options.delete(:filter)
        @formatter = options.delete(:formatter)
        @formatter = self.class.extract_formatter(@formatter) if @formatter.is_a?(Symbol)
        @formatter ||= block
        # Default to #call method for formatting if defined for an appender
        @formatter ||= (respond_to?(:call) ? self : SemanticLogger::Formatters::Default.new)
        raise(ArgumentError, "Unknown options: #{options.inspect}") if options.size > 0

        # Appenders don't take a class name, so use this class name if an appender
        # is logged to directly
        super(self.class, level, filter)
      end

      # Return the level index for fast comparisons
      # Returns the lowest level index if the level has not been explicitly
      # set for this instance
      def level_index
        @level_index || 0
      end

      # Return formatter for supplied Symbol
      def self.extract_formatter(formatter)
        SemanticLogger.send(:named_formatter, formatter).new
      end

    end
  end
end
