module SemanticLogger
  module Formatters
    class Default
      # Default log formatter
      #  Generates logs of the form:
      #    2011-07-19 14:36:15.660 D [1149:ScriptThreadProcess] Rails -- Hello World
      def call(log, logger)
        # Header with date, time, log level and process info
        message = "#{log.formatted_time} #{log.level_to_s} [#{log.process_info}]"

        # Tags
        message << ' ' << log.tags.collect { |tag| "[#{tag}]" }.join(' ') if log.tags && (log.tags.size > 0)

        # Duration
        message << " (#{log.duration_human})" if log.duration

        # Class / app name
        message << " #{log.name}"

        # Log message
        message << " -- #{log.message}" if log.message

        # Payload
        if payload = log.payload_to_s
          message << ' -- ' << payload
        end

        # Exceptions
        if log.exception
          message << " -- Exception: #{log.exception.class}: #{log.exception.message}\n"
          message << log.backtrace_to_s
        end
        message
      end

    end
  end
end

