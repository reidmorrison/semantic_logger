module SemanticLogger
  module Formatters
    # Default non-colored text log output
    class Default < Base
      # Formatting methods, must return nil, or a string
      # Nil values are ignored

      # Log level
      def level
        log.level_to_s
      end

      # Name of the thread that logged the message.
      def thread_name
        format("%.30s", log.thread_name)
      end

      # Ruby file name and line number that logged the message.
      def file_name_and_line
        file, line = log.file_name_and_line(true)
        "#{file}:#{line}" if file
      end

      # Returns [String] the available process info
      # Example:
      #    [18934:thread_name test_logging.rb:51]
      def process_info
        process_id = "#{pid}:" if pid
        fname      = file_name_and_line
        fname ? "[#{process_id}#{thread_name} #{fname}]" : "[#{process_id}#{thread_name}]"
      end

      # Tags
      def tags
        "[#{log.tags.join('] [')}]" if log.tags && !log.tags.empty?
      end

      # Named Tags
      def named_tags
        named_tags = log.named_tags
        return if named_tags.nil? || named_tags.empty?

        list = []
        named_tags.each_pair { |name, value| list << "#{name}: #{value}" }
        "{#{list.join(', ')}}"
      end

      # Duration
      def duration
        "(#{log.duration_human})" if log.duration
      end

      # Class / app name
      def name
        log.name
      end

      # Log message
      def message
        "-- #{log.message}" if log.message
      end

      # Payload
      def payload
        pl = log.payload_to_s
        return unless pl

        "-- #{pl}"
      end

      # Exception
      def exception
        "-- Exception: #{log.exception.class}: #{log.exception.message}\n#{log.backtrace_to_s}" if log.exception
      end

      # Default text log format
      #  Generates logs of the form:
      #    2011-07-19 14:36:15.660235 D [1149:ScriptThreadProcess] Rails -- Hello World
      def call(log, logger)
        self.log    = log
        self.logger = logger

        [time, level, process_info, tags, named_tags, duration, name, message, payload, exception].compact.join(" ")
      end
    end
  end
end
