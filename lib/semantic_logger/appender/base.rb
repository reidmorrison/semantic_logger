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

    # Formatting & colors used by optional colorized_formatter
    module AnsiColors
      CLEAR     = "\e[0m"
      BOLD      = "\e[1m"
      BLACK     = "\e[30m"
      RED       = "\e[31m"
      GREEN     = "\e[32m"
      YELLOW    = "\e[33m"
      BLUE      = "\e[34m"
      MAGENTA   = "\e[35m"
      CYAN      = "\e[36m"
      WHITE     = "\e[37m"

      # Maps the log level to a color for colorized formatters
      # Since this map is not frozen, it can be modified as needed
      LEVEL_MAP = {
        trace: MAGENTA,
        debug: GREEN,
        info:  CYAN,
        warn:  BOLD,
        error: RED,
        fatal: RED
      }
    end

    class Base < SemanticLogger::Base
      attr_accessor :formatter

      # Default log formatter
      #  Replace this formatter by supplying a Block to the initializer
      #  Generates logs of the form:
      #    2011-07-19 14:36:15.660 D [1149:ScriptThreadProcess] Rails -- Hello World
      def default_formatter
        Proc.new do |log|
          # Header with date, time, log level and process info
          entry = "#{log.formatted_time} #{log.level_to_s} [#{log.process_info}]"

          # Tags
          entry << ' ' << log.tags.collect { |tag| "[#{tag}]" }.join(' ') if log.tags && (log.tags.size > 0)

          # Duration
          entry << " (#{log.duration_human})" if log.duration

          # Class / app name
          entry << " #{log.name}"

          # Log message
          entry << " -- #{log.message}" if log.message

          # Payload
          unless log.payload.nil? || (log.payload.respond_to?(:empty?) && log.payload.empty?)
            entry << ' -- ' << log.payload.inspect
          end

          # Exceptions
          log.each_exception do |exception, i|
            entry << (i == 0 ? ' -- Exception: ' : "\nCause: ")
            entry << "#{exception.class}: #{exception.message}\n#{(exception.backtrace || []).join("\n")}"
          end
          entry
        end
      end

      # Optional log formatter to colorize log output
      # To use this formatter
      #   SemanticLogger.add_appender($stdout, &SemanticLogger::Appender::Base.colorized_formatter)
      #
      #    2011-07-19 14:36:15.660 D [1149:ScriptThreadProcess] Rails -- Hello World
      def self.colorized_formatter
        Proc.new do |log|
          colors      = SemanticLogger::Appender::AnsiColors
          level_color = colors::LEVEL_MAP[log.level]

          # Header with date, time, log level and process info
          entry = "#{log.formatted_time} #{level_color}#{log.level_to_s}#{colors::CLEAR} [#{log.process_info}]"

          # Tags
          entry << ' ' << log.tags.collect { |tag| "[#{level_color}#{tag}#{colors::CLEAR}]" }.join(' ') if log.tags && (log.tags.size > 0)

          # Duration
          entry << " (#{colors::BOLD}#{log.duration_human}#{colors::CLEAR})" if log.duration

          # Class / app name
          entry << " #{level_color}#{log.name}#{colors::CLEAR}"

          # Log message
          entry << " -- #{log.message}" if log.message

          # Payload
          unless log.payload.nil? || (log.payload.respond_to?(:empty?) && log.payload.empty?)
            payload = log.payload
            payload = (defined?(AwesomePrint) && payload.respond_to?(:ai)) ? payload.ai(multiline: false) : payload.inspect
            entry << ' -- ' << payload
          end

          # Exceptions
          log.each_exception do |exception, i|
            entry << (i == 0 ? ' -- Exception: ' : "\nCause: ")
            entry << "#{colors::BOLD}#{exception.class}: #{exception.message}#{colors::CLEAR}\n#{(exception.backtrace || []).join("\n")}"
          end
          entry
        end
      end

      def flush
        # An appender can implement a flush method if it supports it.
      end

      # Returns the current log level if set, otherwise it returns the global
      # default log level
      def level
        @level || :trace
      end

      ############################################################################
      protected

      # Initializer for Abstract Class SemanticLogger::Appender
      #
      # Parameters
      #  level [Symbol]
      #    Only allow log entries of this level or higher to be written to this appender
      #    For example if set to :warn, this appender would only log :warn and :fatal
      #    log messages when other appenders could be logging :info and lower
      #
      #  filter [RegExp|Proc]
      #    Optional regular expression to filter log entries based on the class name
      #    When filter is a proc, it is passed the entire log struct and must return
      #    true or false indicating whether to log the message
      def initialize(level=nil, filter=nil, &block)
        # Set the formatter to the supplied block
        @formatter = block || default_formatter

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

      if defined? Java
        # Return the Time as a formatted string
        # JRuby only supports time in ms
        def self.formatted_time(time)
          warn '[deprecated] SemanticLogger::Base.formatted_time is deprecated please use log.formatted_time'
          "#{time.strftime('%Y-%m-%d %H:%M:%S')}.#{'%03d' % (time.usec/1000)}"
        end
      else
        # Return the Time as a formatted string
        # Ruby MRI supports micro seconds
        def self.formatted_time(time)
          warn '[deprecated] SemanticLogger::Base.formatted_time is deprecated please use log.formatted_time'
          "#{time.strftime('%Y-%m-%d %H:%M:%S')}.#{'%06d' % (time.usec)}"
        end
      end

    end
  end
end
