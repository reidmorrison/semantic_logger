begin
  require 'honeybadger'
rescue LoadError
  raise 'Gem honeybadger is required for logging purposes. Please add the gem "honeybadger" to your Gemfile.'
end

# Formatter for the Honeybadger appender
# Takes into account the honeybadger request/context expected by the gem
class SemanticLogger::Formatters::Honeybadger < SemanticLogger::Formatters::Raw
  # Returns a hash of options compatible with what Honeybadger::Notice expects
  def call(log, appender)
    formatted = { tags: log.tags, context: super }
    format_error(log, formatted)

    if log.has_context?(appender.class)
      honeybadger = log.appender_context[appender.class]

      if honeybadger.is_a?(Hash) && !honeybadger.empty?
        formatted[:request] = honeybadger[:request]
        formatted[:context].merge!(format_context(honeybadger))
      end
    end

    return formatted
  end

  def format_error(log, formatted)
    if log.exception.is_a?(Exception)
      formatted[:exception] = log.exception
      formatted[:context].delete(:exception) # remove from context info
      formatted[:backtrace] = log.exception.backtrace
    else
      formatted[:error_class] = formatted[:context].delete(:name)
      formatted[:error_message] = formatted[:context].delete(:message)
      formatted[:backtrace] = log.backtrace if log.backtrace
    end
  end
  private :format_error

  def format_context(info)
    formatted = {}
    context = info[:context]

    return formatted if context.nil?

    if context.is_a?(Hash)
      formatted = context
    else
      formatted[:honeybadger] = context
    end

    return formatted
  end
  private :format_context
end
