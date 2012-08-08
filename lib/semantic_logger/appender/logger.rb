# Logger appender
#
#   Maps the SemanticLogger API's to the Rails log, log4j, or Ruby Logger
#
# Installation:
#    Rails.logger = SemanticLogger::Appender::Logger.new(Rails.logger)
#
# Also works with the Ruby Logger
#    require 'logger'
#    require 'semantic_logger'
#    logger = Logger.new(STDOUT)
#    Rails.log = SemanticLogger::Appender::Logger.new(logger)
#
# ActiveResource::BufferedLogger
#    ...
#
# The log level is controlled by the Logging implementation passed into
# this appender
module SemanticLogger
  module Appender
    class Logger
      attr_reader :logger

      def initialize(logger)
        raise "logger cannot be null when initiailizing the SemanticLogging::Appender::Logger" unless logger
        @logger = logger
      end

      # The default log formatter
      # Generates logs of the form:
      #    2011-07-19 14:36:15.660 D [1149:ScriptThreadProcess] Rails -- Hello World
      @@formatter = Proc.new do |level, name, message, time, duration|
        str = "#{time.strftime("%Y-%m-%d %H:%M:%S")}.#{"%03d" % (time.usec/1000)} #{level.to_s[0..0].upcase} [#{$$}:#{thread_name}] #{name} -- #{message}\n"
        str << " (#{duration}ms)" if duration
        str
      end

      # For JRuby include the Thread name rather than its id
      if defined? Java
        def self.thread_name
          Java::java.lang::Thread.current_thread.name
        end
      else
        def self.thread_name
          Thread.object_id
        end
      end

      # Allow the global formatter to be replaced
      def self.formatter=(formatter)
        @@formatter = formatter
      end

      # Pass log calls to the underlying Rails, log4j or Ruby logger
      #  trace entries are mapped to debug since :trace is not supported by the
      #  Ruby or Rails Loggers
      def log(level, name, message, hash, &block)
        @logger.send(level == :trace ? :debug : level) { self.class.format_message(level, name, message, hash, &block) }
      end

      # Convert a semantic log entry into plain text
      def self.format_message(level, name, message, hash=nil, &block)
        # TODO need to define :try if not already defined. E.g. Outside Rails
        msg = time = duration = nil
        if hash
          msg      = hash.delete(:message)
          time     = hash.delete(:time)
          duration = hash.delete(:duration)
        end
        msg  ||= message.to_s
        time ||= Time.now

        msg << " -- " << self.msg2str(hash) if hash
        msg << " -- " << self.msg2str(block.call) if block
        @@formatter.call(level, name, msg, time, duration)
      end

      # Convert Objects to Strings for text based logging
      def self.msg2str(message)
        case message
        when ::String
          message
        when ::Exception
          "#{message.class}: #{message.message}\n#{(message.backtrace || []).join("\n")}"
        when ::Hash
          # With a hash, the message can be an element of the hash itself
          if msg = message[:message]
            # Cannot change supplied hash
            hash = message.clone
            hash.delete(:message)
            "#{msg} #{hash.inspect}"
          else
            message.inspect
          end
        else
          message.inspect
        end
      end

    end
  end
end
