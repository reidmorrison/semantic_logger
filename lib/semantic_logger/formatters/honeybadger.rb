# frozen_string_literal: true

class SemanticLogger::Formatters::Honeybadger < SemanticLogger::Formatters::Raw
  # see: https://docs.honeybadger.io/ruby/getting-started/reporting-errors.html
  # for a list of all possible option keys accepted by honeybadger. context is kept
  # out as it is handled differently, but even when passed, will get merged with
  # all other contexts.
  OPTION_KEYS = %i[action backtrace controller error_message error_class fingerprint force parameters session tags url].freeze

  # Returns a hash of options compatible with what Honeybadger::Notice expects
  def call(log, appender)
    context = log.context.nil? ? nil : log.context[:honeybadger]
    formatted = {
      context: {}, # passed to Honeybadger.context
      rack_env: {}, # passed to Honeybadger.with_rack_env
      options: {}, # options passed to Honeybadger.notify call
      message: nil # first argument passed to Honeybadger.notify call (either message or Exception)
    }

    unless context.nil?
      formatted[:context] = context[:context] || {}
      formatted[:rack_env] = context[:rack_env]
    end

    payload = log.payload.dup # dup it to avoid modifying it for further subscribers
    unless payload.nil?
      honeybadger = payload.delete(:honeybadger)
      formatted[:context].merge!(payload)

      if honeybadger.is_a?(Hash)
        formatted[:options].merge!(honeybadger.select { |key, _| OPTION_KEYS.include?(key) })
        formatted[:context].merge!(honeybadger[:context]) if honeybadger[:context].is_a?(Hash)
      end
      formatted[:options][:tags] = format_tags(log, formatted[:options][:tags])
    end

    if log.exception.nil?
      formatted[:message] = log.message
      formatted[:options][:backtrace] ||= log.backtrace
      formatted[:options][:error_class] ||= log.name
    else
      formatted[:message] = log.exception
    end

    return formatted
  end

  private

  def format_tags(log, initial = nil)
    binding.pry
    tags = case initial
    when String then initial.split(',')
    when Array then initial
    else
      []
    end

    return (log.tags + tags).join(', ') # must be comma-space as of Honeybadger 3.0
  end
end
