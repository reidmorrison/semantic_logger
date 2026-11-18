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
    # each element that cannot be copied replaced, and any other value replaced by its #inspect. A
    # Hash or an Array is always rebuilt, so that each value in it is tried once, not with every Hash
    # or Array that holds it.
    def self.copyable(value, depth = 0)
      case value
      when Hash
        return Utils.safe_inspect(value) if depth >= Utils::MAX_JSON_SAFE_DEPTH

        value.to_h { |key, val| [copyable(key, depth + 1), copyable(val, depth + 1)] }
      when Array
        return Utils.safe_inspect(value) if depth >= Utils::MAX_JSON_SAFE_DEPTH

        value.map { |element| copyable(element, depth + 1) }
      else
        plain?(value) || copyable?(value) ? value : Utils.safe_inspect(value)
      end
    end

    # Returns the exception when it can be copied to another Ractor. Otherwise a copy of the same
    # class with the message it was raised with, its backtrace, its cause, which is copied the same
    # way, and its instance variables, made copyable as by .copyable. Or a RuntimeError with the class
    # name in its message, for an exception whose #message needs what could not be copied.
    def self.copyable_exception(exception, depth = 0)
      copyable?(exception) ? exception : plain_exception(exception, depth)
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

    # Whether the value is one that Ruby always copies, so that .copyable need not try it.
    def self.plain?(value)
      case value
      when nil, true, false, Symbol, Integer, Float
        true
      when String
        value.instance_of?(String) && value.instance_variables.empty?
      else
        false
      end
    end
    private_class_method :plain?

    def self.plain_exception(exception, depth)
      copy = exception.class.allocate
      Exception.instance_method(:initialize).bind_call(copy, Utils.raised_message(exception))
      exception.instance_variables.each do |name|
        copy.instance_variable_set(name, copyable_variable(exception.instance_variable_get(name), depth))
      end
      copy.set_backtrace(exception.backtrace || [])
      copy = with_cause(copy, exception.cause, depth)
      # Raises when the class's #message needs a value that could not be copied.
      copy.message
      copy
    rescue StandardError
      plain = RuntimeError.new("#{Utils.exception_name(exception)}: #{Utils.exception_message(exception)}")
      plain.set_backtrace(exception.backtrace || [])
      with_cause(plain, exception.cause, depth)
    end
    private_class_method :plain_exception

    def self.copyable_variable(value, depth)
      return copyable(value, depth + 1) unless value.is_a?(Exception)

      depth < Log::MAX_EXCEPTIONS_TO_UNWRAP ? copyable_exception(value, depth + 1) : Utils.safe_inspect(value)
    end
    private_class_method :copyable_variable

    # Returns the copy of an exception with a copy of its cause. Ruby only sets the cause of an
    # exception when raising it, and keeps the backtrace already set.
    def self.with_cause(copy, cause, depth)
      return copy unless cause && depth < Log::MAX_EXCEPTIONS_TO_UNWRAP

      begin
        raise copy, cause: copyable_exception(cause, depth + 1)
      rescue Exception => e
        e
      end
    end
    private_class_method :with_cause
  end
end
