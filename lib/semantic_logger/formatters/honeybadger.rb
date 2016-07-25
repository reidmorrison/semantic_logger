# Formatter to be used with the Honeybadger appender
class SemanticLogger::Formatters::Honeybadger < SemanticLogger::Formatters::Raw
  # Merges existing context with a ::Honeybadger::Util::RequestPayload hash
  # See: https://github.com/honeybadger-io/honeybadger-ruby/blob/master/lib/honeybadger/util/request_payload.rb
  def call(log, appender)
    context = super
    callee = thread_by_name(log.thread_name)

    if callee && callee.respond_to?(:[])
      request = callee[:__honeybadger_request]

      if request && request.respond_to?(:env)
        hash = ::Honeybadger::Rack::RequestHash.new(request)

        unless hash.nil?
          payload = ::Honeybadger::Util::RequestPayload.build(hash)
          context = payload.merge(context) if payload.respond_to?(:merge)
        end
      end
    end

    return context
  end

  # Extracts a named thread from the list of all threads.
  def thread_by_name(name)
    return Thread.list.find { |t| t.name == name }
  end
end
