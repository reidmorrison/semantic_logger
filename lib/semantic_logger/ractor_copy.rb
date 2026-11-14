module SemanticLogger
  # Internal, experimental: what Ruby can copy from one Ractor to another, and how to replace what it
  # cannot. Ruby 4.0 and later only.
  #
  # Sending a value to another Ractor copies it, unless it is shareable. Ruby cannot copy some
  # objects, such as a Proc, a Thread, a Method, or an Enumerator, or anything that holds one.
  module RactorCopy
    # Returns [Array] the log entry, and the backtraces of its exceptions, to send to another Ractor.
    #
    # Ruby 4.0 leaves an exception copied to another Ractor without its backtrace (Ruby bug #21818), so
    # .unpack sets it again.
    def self.pack(log)
      backtraces = []
      log.each_exception { |exception, i| backtraces[i] = exception.backtrace }
      [log, backtraces]
    end

    # Returns [Log] the log entry received from another Ractor (see .pack), with the backtraces of its
    # exceptions.
    def self.unpack(log, backtraces)
      log.each_exception do |exception, i|
        backtrace = backtraces[i]
        exception.set_backtrace(backtrace) if backtrace && exception.backtrace != backtrace
      end
      log
    end

    # Returns the value when it can be copied to another Ractor. Otherwise a Hash or an Array with
    # each element that cannot be copied replaced, and any other value replaced by its #inspect.
    def self.copyable(value, depth = 0)
      return value if copyable?(value)

      if depth < Utils::MAX_JSON_SAFE_DEPTH && value.is_a?(Hash)
        value.to_h { |key, val| [copyable?(key) ? key : Utils.safe_inspect(key), copyable(val, depth + 1)] }
      elsif depth < Utils::MAX_JSON_SAFE_DEPTH && value.is_a?(Array)
        value.map { |element| copyable(element, depth + 1) }
      else
        Utils.safe_inspect(value)
      end
    end

    # Returns the exception when it can be copied to another Ractor. Otherwise a copy of the same
    # class with only its message, backtrace, and cause, which is copied the same way. Or a
    # RuntimeError with the class name in its message, for an exception that cannot be copied even so.
    def self.copyable_exception(exception)
      copyable?(exception) ? exception : plain_exception(exception)
    end

    # Whether the value can be copied to another Ractor: sends it through a port of this Ractor.
    def self.copyable?(value)
      port = ::Ractor::Port.new
      port << value
      port.receive
      true
    rescue StandardError
      false
    ensure
      port&.close
    end

    def self.plain_exception(exception, depth = 0)
      copy = exception.class.allocate
      Exception.instance_method(:initialize).bind_call(copy, exception.message)
      copy.set_backtrace(exception.backtrace || [])
      cause = exception.cause
      return copy unless cause && depth < Log::MAX_EXCEPTIONS_TO_UNWRAP

      # Ruby only sets the cause of an exception when raising it, and keeps a backtrace already set.
      begin
        raise copy, cause: plain_exception(cause, depth + 1)
      rescue Exception => e
        e
      end
    rescue StandardError
      RuntimeError.new("#{exception.class.name}: #{exception.message}").tap do |copy|
        copy.set_backtrace(exception.backtrace || [])
      end
    end
    private_class_method :plain_exception
  end
end
