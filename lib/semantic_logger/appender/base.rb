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
          tags = log.tags.collect { |tag| "[#{tag}]" }.join(" ") + " " if log.tags && (log.tags.size > 0)

          message = log.message.to_s.dup
          message << " -- " << log.payload.inspect if log.payload
          message << " -- Exception: " << "#{log.exception.class}: #{log.exception.message}\n#{(log.exception.backtrace || []).join("\n")}" if log.exception

          duration_str = log.duration ? "(#{'%.1f' % log.duration}ms) " : ''

          "#{SemanticLogger::Appender::Base.formatted_time(log.time)} #{log.level.to_s[0..0].upcase} [#{$$}:#{'%.50s' % log.thread_name}] #{tags}#{duration_str}#{log.name} -- #{message}"
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
          tags = log.tags.collect { |tag| "[#{colors::CYAN}#{tag}#{colors::CLEAR}]" }.join(' ') + ' ' if log.tags && (log.tags.size > 0)

          message = log.message.to_s.dup
          message << " -- " << log.payload.inspect if log.payload
          message << " -- Exception: " << "#{colors::BOLD}#{log.exception.class}: #{log.exception.message}#{colors::CLEAR}\n#{(log.exception.backtrace || []).join("\n")}" if log.exception

          duration_str = log.duration ? "(#{colors::BOLD}#{'%.1f' % log.duration}ms#{colors::CLEAR}) " : ''

          level_color = case log.level
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

          "#{SemanticLogger::Appender::Base.formatted_time(log.time)} #{level_color}#{colors::BOLD}#{log.level.to_s[0..0].upcase}#{colors::CLEAR} [#{$$}:#{'%.30s' % log.thread_name}] #{tags}#{duration_str}#{level_color}#{log.name}#{colors::CLEAR} -- #{message}"
        end
      end

      ############################################################################
      protected

      # By default the appender should log everything that is sent to it by
      # the loggers. That way the loggers control the log level
      # By setting the log level to a higher value the appender can be setup
      # to log for example only :warn or higher while other appenders
      # are able to log lower level information
      def initialize(level, &block)
        # Set the formatter to the supplied block
        @formatter = block || default_formatter

        # Appenders don't take a class name, so use this class name if an appender
        # is logged to directly
        super(self.class, level || :trace)
      end

      # For JRuby include the Thread name rather than its id
      if defined? Java
        # Return the Time as a formatted string
        # JRuby only supports time in ms
        def self.formatted_time(time)
          "#{time.strftime("%Y-%m-%d %H:%M:%S")}.#{"%03d" % (time.usec/1000)}"
        end
      else
        # Return the Time as a formatted string
        # Ruby MRI supports micro seconds
        def self.formatted_time(time)
          "#{time.strftime("%Y-%m-%d %H:%M:%S")}.#{"%06d" % (time.usec)}"
        end
      end

    end
  end
end