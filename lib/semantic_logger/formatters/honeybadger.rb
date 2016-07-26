begin
  require 'honeybadger'
rescue LoadError
  raise 'Gem honeybadger is required for logging purposes. Please add the gem "honeybadger" to your Gemfile.'
end

# Formatter for the Honeybadger appender
# Takes into account the honeybadger request/context expected by the gem
class SemanticLogger::Formatters::Honeybadger < SemanticLogger::Formatters::Raw
  THREAD_VARIABLE_REQUEST = :__honeybadger_request
  THREAD_VARIABLE_CONTEXT = :__honeybadger_context
  SEMANTIC_CONTEXT_KEYS = [:name, :pid, :thread, :time, :level, :level_index, :host, :application, :file, :line, :payload].freeze

  # Returns a hash of options compatible with what Honeybadger::Notice expects
  def call(log, appender)
    options = { tags: log.tags }
    options[:context] = super.select { |key, _| SEMANTIC_CONTEXT_KEYS.include?(key) }

    if log.exception.is_a?(Exception)
      options[:exception] = log.exception
    else
      options[:error_class] = log.name
      options[:error_message] = log.message
    end
    options[:backtrace] = log.backtrace if log.backtrace

    if log.thread_context
      options[:request] = log.thread_context[THREAD_VARIABLE_REQUEST]
      honeybadger_context = log.thread_context[THREAD_VARIABLE_CONTEXT]
      if honeybadger_context.is_a?(Hash)
        options[:context].merge!(honeybadger_context)
      else
        options[:context][:honeybadger_context] = honeybadger_context
      end
    end

    return options
  end
end
