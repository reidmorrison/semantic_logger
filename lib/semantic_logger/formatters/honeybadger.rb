require 'honeybadger/util/request_payload'

# Formatter to be used with the Honeybadger appender
class SemanticLogger::Formatters::Honeybadger < SemanticLogger::Formatters::Raw
  CONTEXT_KEY = :__honeybadger_request

  # Merges existing context with a ::Honeybadger::Util::RequestPayload hash
  # See: https://github.com/honeybadger-io/honeybadger-ruby/blob/master/lib/honeybadger/util/request_payload.rb
  # Keep in mind this only works if the caller thread is still alive, which should be the case for a standard Rails app
  def call(log, appender)
    context = super
    caller = Thread.find_by_name(log.thread_name)

    if caller && caller.respond_to?(:[])
      request = caller[CONTEXT_KEY]

      if request && request.respond_to?(:env) && request.respond_to?(:session)
        hash = ::Honeybadger::Rack::RequestHash.new(request)

        unless hash.nil?
          payload = ::Honeybadger::Util::RequestPayload.build(hash)
          context = payload.merge(context) if payload.respond_to?(:merge)
        end
      end
    end

    return context
  end
end
