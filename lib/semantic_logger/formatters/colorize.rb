# Load AwesomePrint if available
begin
  require 'awesome_print'
rescue LoadError
end

module SemanticLogger
  module Formatters
    class Colorize
      # Adds color to the default log formatter
      # Example:
      #   SemanticLogger.add_appender($stdout, SemanticLogger::Formatters::Colorize.new)
      def call(log, logger)
        colors      = SemanticLogger::AnsiColors
        level_color = colors::LEVEL_MAP[log.level]

        # Header with date, time, log level and process info
        message     = "#{log.formatted_time} #{level_color}#{log.level_to_s}#{colors::CLEAR} [#{log.process_info}]"

        # Tags
        message << ' ' << log.tags.collect { |tag| "[#{level_color}#{tag}#{colors::CLEAR}]" }.join(' ') if log.tags && (log.tags.size > 0)

        # Duration
        message << " (#{colors::BOLD}#{log.duration_human}#{colors::CLEAR})" if log.duration

        # Class / app name
        message << " #{level_color}#{log.name}#{colors::CLEAR}"

        # Log message
        message << " -- #{log.message}" if log.message

        # Payload: Colorize the payload if the AwesomePrint gem is loaded
        if has_payload?
          message << ' -- ' <<
            if !defined?(AwesomePrint) || !payload.respond_to?(:ai)
              payload.inspect
            else
              payload.ai(multiline: false) rescue payload.inspect
            end
        end

        # Exceptions
        if log.exception
          message << " -- Exception: #{colors::BOLD}#{log.exception.class}: #{log.exception.message}#{colors::CLEAR}\n"
          message << log.backtrace_to_s
        end
        message
      end

    end
  end
end

