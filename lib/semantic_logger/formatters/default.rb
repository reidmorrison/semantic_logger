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

      # Name of the thread that logged the message, shortened before it is escaped, so that an
      # escape is never cut in two.
      def thread_name
        escape_control_characters(shortened_thread_name)
      end

      # Ruby file name and line number that logged the message, followed by the method when the
      # entry has a call site (see SemanticLogger.call_site_level), such as "order.rb:42 Order#submit".
      #
      # The file name is escaped like the other fields, since it comes from the first line of the
      # backtrace, which a log call can supply from untrusted data.
      def file_name_and_line
        file, line = log.file_name_and_line(true)
        return unless file

        label = method_name
        label ? "#{escape_control_characters(file)}:#{line} #{label}" : "#{escape_control_characters(file)}:#{line}"
      end

      # The method that logged the message, such as "Order#submit", when the entry has a call site.
      # Escaped like the file name, which it comes from.
      def method_name
        escape_control_characters(log.call_site&.label)
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
        return if log.tags.nil? || log.tags.empty?

        "[#{log.tags.map { |tag| escape_control_characters(tag) }.join('] [')}]"
      end

      # Named Tags
      def named_tags
        named_tags = log.named_tags
        return if named_tags.nil? || named_tags.empty?

        list = []
        named_tags.each_pair do |name, value|
          list << "#{escape_control_characters(name)}: #{escape_control_characters(value)}"
        end
        "{#{list.join(', ')}}"
      end

      # Duration
      def duration
        "(#{log.duration_human})" if log.duration
      end

      # Class / app name
      def name
        escape_control_characters(log.name)
      end

      # Log message
      def message
        "-- #{escape_control_characters(log.message)}" if log.message
      end

      # Payload
      def payload
        pl = log.payload_to_s
        return unless pl

        "-- #{escape_control_characters(pl)}"
      end

      # Exception
      def exception
        return unless log.exception

        message = escape_control_characters(Utils.exception_message(log.exception))
        "-- Exception: #{Utils.exception_name(log.exception)}: #{message}#{exception_detail_lines}"
      end

      # The detail Ruby adds to the exception's message, such as did_you_mean suggestions.
      # See Base#initialize for the `log_exception_details` option.
      def exception_details
        escape_control_characters(exception_details_for(log.exception)) if log.exception
      end

      # Default text log format
      #  Generates logs of the form:
      #    2011-07-19 14:36:15.660235 D [1149:ScriptThreadProcess] Rails -- Hello World
      def call(log, logger)
        self.log    = log
        self.logger = logger

        [time, level, process_info, tags, named_tags, duration, name, message, payload, exception].compact.join(" ")
      end

      private

      # Returns [String] the name of the thread, shortened to 30 characters. A name that holds bytes
      # outside ASCII in another encoding, such as a binary name that holds UTF-8, is converted
      # first (see #joinable_text), so that it is shortened by characters, rather than by bytes,
      # which would split a character in two.
      def shortened_thread_name = format("%.30s", joinable_text(log.thread_name))

      # Returns [String] the exception details and backtrace that follow the exception line, each
      # starting on a new line. Empty when there are neither, such as for an exception that was
      # never raised, so that no blank line follows the exception.
      def exception_detail_lines
        [exception_details, exception_backtrace].filter_map { |text| "\n#{text}" unless text.nil? || text.empty? }.join
      end

      # Text output is read by people, who benefit most from exception details.
      def default_log_exception_details
        true
      end

      # Text output is read by people, who are best served by the frames of their own code.
      def default_backtrace_cleaner
        true
      end
    end
  end
end
