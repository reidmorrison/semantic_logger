# File appender
#
#   Writes log messages to a file or open iostream
#
module SemanticLogger
  module Appender
    class File
      attr_accessor :formatter

      # Create a File Logger appender instance
      #
      # Example
      #    require 'semantic_logger'
      #
      #    # Log to screen
      #    SemanticLogger::Logger.appenders << SemanticLogger::Appender::File.new(STDOUT)
      #
      #    # And log to a file at the same time
      #    SemanticLogger::Logger.appenders << SemanticLogger::Appender::File.new('application.log')
      #
      #    logger =  SemanticLogger::Logger.new('test')
      #    logger.info 'Hello World'
      #
      def initialize(filename, &block)
        raise "logger cannot be null when initializing the SemanticLogging::Appender::Logger" unless filename
        @filename = filename
        @log = if filename.respond_to?(:write) and filename.respond_to?(:close)
          filename
        else
          @log = open(filename, (::File::WRONLY | ::File::APPEND | ::File::CREAT))
          # Force all log entries to write immediately without buffering
          @log.sync = true
          @log.set_encoding(Encoding::BINARY) if @log.respond_to?(:set_encoding)
          @log
        end

        # Set the formatter to the supplied block
        @formatter = block || self.default_formatter
      end

      # Default log formatter
      #  Replace this formatter by supplying a Block to the initializer
      #  Generates logs of the form:
      #    2011-07-19 14:36:15.660 D [1149:ScriptThreadProcess] Rails -- Hello World\n
      def default_formatter
        Proc.new do |log|
          message = log.message.to_s
          tags = log.tags.collect { |tag| "[#{tag}]" }.join(" ") + " " if log.tags && (log.tags.size > 0)

          if log.payload
            if log.payload.is_a?(Exception)
              exception = log.payload
              message << " -- " << "#{exception.class}: #{exception.message}\n#{(exception.backtrace || []).join("\n")}"
            else
              message << " -- " << log.payload.inspect
            end
          end

          str = "#{log.time.strftime("%Y-%m-%d %H:%M:%S")}.#{"%03d" % (log.time.usec/1000)} #{log.level.to_s[0..0].upcase} [#{$$}:#{log.thread_name}] #{tags}#{log.name} -- #{message}"
          str << " (#{'%.1f' % log.duration}ms)" if log.duration
          str << "\n"
          str
        end
      end

      # Pass log calls to the underlying Rails, log4j or Ruby logger
      #  trace entries are mapped to debug since :trace is not supported by the
      #  Ruby or Rails Loggers
      def log(log)
        # Since only one appender thread will be writing to the file at a time
        # it is not necessary to protect access to the file with a semaphore
        @log.write(@formatter.call(log))
      end

      # Flush all pending logs to disk.
      #  Waits for all sent documents to be writted to disk
      def flush
        @log.flush if @log.respond_to?(:flush)
      end

    end
  end
end
