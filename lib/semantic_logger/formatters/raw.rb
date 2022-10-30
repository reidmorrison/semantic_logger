require "json"
module SemanticLogger
  module Formatters
    class Raw < Base
      # Fields are added by populating this hash.
      attr_accessor :hash, :time_key

      # By default Raw formatter does not reformat the time
      def initialize(time_format: :none, time_key: :time, **args)
        @time_key = time_key
        super(time_format: time_format, **args)
      end

      # Host name
      def host
        hash[:host] = logger.host if log_host && logger.host
      end

      # Application name
      def application
        hash[:application] = logger.application if log_application && logger && logger.application
      end

      # Environment
      def environment
        hash[:environment] = logger.environment if log_environment && logger && logger.environment
      end

      # Date & time
      def time
        hash[time_key] = format_time(log.time)
      end

      # Log level
      def level
        hash[:level]       = log.level
        hash[:level_index] = log.level_index
      end

      # Process ID
      def pid
        hash[:pid] = super
      end

      # Name of the thread that logged the message.
      def thread_name
        hash[:thread] = log.thread_name
      end

      # Ruby file name and line number that logged the message.
      def file_name_and_line
        file, line = log.file_name_and_line
        return unless file

        hash[:file] = file
        hash[:line] = line.to_i
      end

      # Tags
      def tags
        hash[:tags] = log.tags if log.tags && !log.tags.empty?
      end

      # Named Tags
      def named_tags
        hash[:named_tags] = log.named_tags if log.named_tags && !log.named_tags.empty?
      end

      # Duration
      def duration
        return unless log.duration

        hash[:duration_ms] = log.duration
        hash[:duration]    = log.duration_human
      end

      # Class / app name
      def name
        hash[:name] = log.name
      end

      # Log message
      def message
        hash[:message] = log.cleansed_message if log.message
      end

      # Payload
      def payload
        hash[:payload] = log.payload if log.payload.respond_to?(:empty?) && !log.payload.empty?
      end

      # Exception
      def exception
        return unless log.exception

        root = hash
        log.each_exception do |exception, i|
          name       = i.zero? ? :exception : :cause
          root[name] = {
            name:        exception.class.name,
            message:     exception.message,
            stack_trace: exception.backtrace
          }
          root = root[name]
        end
      end

      # Metric
      def metric
        hash[:metric]        = log.metric if log.metric
        hash[:metric_amount] = log.metric_amount if log.metric_amount
      end

      # Returns log messages in Hash format
      def call(log, logger)
        self.hash   = {}
        self.log    = log
        self.logger = logger

        host
        application
        environment
        time
        level
        pid
        thread_name
        file_name_and_line
        duration
        tags
        named_tags
        name
        message
        payload
        exception
        metric

        hash
      end
    end
  end
end
