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
      CLEAR   = "\e[0m"
      BOLD    = "\e[1m"
      BLACK   = "\e[30m"
      RED     = "\e[31m"
      GREEN   = "\e[32m"
      YELLOW  = "\e[33m"
      BLUE    = "\e[34m"
      MAGENTA = "\e[35m"
      CYAN    = "\e[36m"
      WHITE   = "\e[37m"
    end

    class Base < SemanticLogger::Base
      attr_accessor :formatter

      # Default log formatter
      #  Replace this formatter by supplying a Block to the initializer
      #  Generates logs of the form:
      #    2011-07-19 14:36:15.660 D [1149:ScriptThreadProcess] Rails -- Hello World
      def default_formatter
        Proc.new do |log|
          tags = log.tags.collect { |tag| "[#{tag}]" }.join(' ') + ' ' if log.tags && (log.tags.size > 0)

          message = log.message.to_s.dup
          message << ' -- ' << log.payload.inspect unless log.payload.nil? || (log.payload.respond_to?(:empty?) && log.payload.empty?)
          message << ' -- Exception: ' << "#{log.exception.class}: #{log.exception.message}\n#{(log.exception.backtrace || []).join("\n")}" if log.exception

          duration_str = log.duration ? "(#{'%.1f' % log.duration}ms) " : ''

          file_name =
            if log.backtrace || log.exception
              backtrace  = log.backtrace || log.exception.backtrace
              location   = backtrace[0].split('/').last
              file, line = location.split(':')
              " #{file}:#{line}"
            end

          "#{SemanticLogger::Appender::Base.formatted_time(log.time)} #{log.level.to_s[0..0].upcase} [#{$$}:#{'%.50s' % log.thread_name}#{file_name}] #{tags}#{duration_str}#{log.name} -- #{message}"
        end
      end

      # Optional log formatter to colorize log output
      # To use this formatter
      #   SemanticLogger.add_appender($stdout, nil, &SemanticLogger::Logger.colorized_formatter)
      #
      #    2011-07-19 14:36:15.660 D [1149:ScriptThreadProcess] Rails -- Hello World
      def self.colorized_formatter
        Proc.new do |log|
          colors = SemanticLogger::Appender::AnsiColors
          tags   = log.tags.collect { |tag| "[#{colors::CYAN}#{tag}#{colors::CLEAR}]" }.join(' ') + ' ' if log.tags && (log.tags.size > 0)

          message = log.message.to_s.dup
          unless log.payload.nil? || (log.payload.respond_to?(:empty?) && log.payload.empty?)
            payload = log.payload
            payload = (defined?(AwesomePrint) && payload.respond_to?(:ai)) ? payload.ai(multiline: false) : payload.inspect
            message << ' -- ' << payload
          end
          message << ' -- Exception: ' << "#{colors::BOLD}#{log.exception.class}: #{log.exception.message}#{colors::CLEAR}\n#{(log.exception.backtrace || []).join("\n")}" if log.exception

          duration_str = log.duration ? "(#{colors::BOLD}#{'%.1f' % log.duration}ms#{colors::CLEAR}) " : ''

          level_color =
            case log.level
            when :trace
              colors::MAGENTA
            when :debug
              colors::GREEN
            when :info
              colors::CYAN
            when :warn
              colors::BOLD
            when :error, :fatal
              colors::RED
            end

          file_name =
            if log.backtrace || log.exception
              backtrace = log.backtrace || log.exception.backtrace
              location = backtrace[0].split('/').last
              file, line = location.split(':')
              " #{level_color}#{file}:#{line}#{colors::CLEAR}"
            end

          "#{SemanticLogger::Appender::Base.formatted_time(log.time)} #{level_color}#{colors::BOLD}#{log.level.to_s[0..0].upcase}#{colors::CLEAR} [#{$$}:#{'%.30s' % log.thread_name}#{file_name}] #{tags}#{duration_str}#{level_color}#{log.name}#{colors::CLEAR} -- #{message}"
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

      # For JRuby include the Thread name rather than its id
      if defined? Java
        # Return the Time as a formatted string
        # JRuby only supports time in ms
        def self.formatted_time(time)
          "#{time.strftime('%Y-%m-%d %H:%M:%S')}.#{'%03d' % (time.usec/1000)}"
        end
      else
        # Return the Time as a formatted string
        # Ruby MRI supports micro seconds
        def self.formatted_time(time)
          "#{time.strftime('%Y-%m-%d %H:%M:%S')}.#{'%06d' % (time.usec)}"
        end
      end

    end
  end
end
