module SemanticLogger
  module Formatters
    # Default non-colored text log output
    class Default < Base
      attr_accessor :log, :logger

      # Formatting methods, must return nil, or a string
      # Nil values are ignored

      # Log level
      def level
        log.level_to_s
      end

      # Process info
      def process_info
        "[#{log.process_info}]"
      end

      # Tags
      def tags
        "[#{log.tags.join('] [')}]" if log.tags && !log.tags.empty?
      end

      # Named Tags
      def named_tags
        if (named_tags = log.named_tags) && !named_tags.empty?
          list = []
          named_tags.each_pair { |name, value| list << "#{name}: #{value}" }
          "{#{list.join(', ')}}"
        end
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
        if pl = log.payload_to_s
          "-- #{pl}"
        end
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

        [time, level, process_info, duration, tags, named_tags, name, message, payload, exception].compact.join(' ')
      end

    end
  end
end

