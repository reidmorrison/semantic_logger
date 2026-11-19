module SemanticLogger
  # Asks an application's backtrace cleaner, such as `Rails.backtrace_cleaner`, to clean a backtrace.
  #
  # A backtrace cleaner is any object that responds to `#clean`, as ActiveSupport::BacktraceCleaner
  # does, or to `#call`, such as a Proc. It is given the backtrace as an Array of Strings, and
  # returns the lines to log in its place: it can leave lines out, and shorten or rewrite them.
  #
  # Internal: Log caches the result for each of its exceptions; see Log#backtrace_of.
  module BacktraceCleaning
    # Returns [true|false] whether the object can clean a backtrace.
    def self.cleaner?(object)
      object.respond_to?(:clean) || object.respond_to?(:call)
    end

    # Returns the cleaner, for a setting that holds one.
    # Raises ArgumentError when it cannot clean a backtrace (see .cleaner?), naming what the
    # setting expects, since it can accept other values too.
    def self.validate!(cleaner, expected: "a backtrace cleaner")
      return cleaner if cleaner?(cleaner)

      raise(ArgumentError, "Expected #{expected} that responds to #clean or #call, not #{cleaner.inspect}")
    end

    # Returns [Array<String>] the backtrace as the cleaner cleans it, or nil when there is none.
    # The Array and its lines are frozen copies, so that every appender can share them.
    #
    # Returns a copy of the supplied backtrace instead when the cleaner leaves out every line, so
    # that the only clue to where an exception came from is never lost, for example an exception
    # raised entirely within gems that a cleaner silences. Also when the cleaner does not return an
    # Array of lines, or raises a StandardError, such as for an object that is not a cleaner, so
    # that a cleaner cannot stop a log entry being written. The error is reported to the internal
    # logger, since nothing else would show that the cleaner is broken.
    #
    # The cleaner is given a copy of the backtrace, which it may change, since the supplied one
    # belongs to the exception, and other appenders, such as error services, also read it.
    def self.clean(backtrace, cleaner)
      return if backtrace.nil?

      cleaned_lines(backtrace, cleaner) || frozen_copy(backtrace)
    end

    # Returns [Array<String>] a frozen copy of the lines the cleaner keeps, or nil when it keeps
    # none, does not return an Array of lines, or raises.
    def self.cleaned_lines(backtrace, cleaner)
      return if backtrace.empty?

      lines   = backtrace.dup
      cleaned = cleaner.respond_to?(:clean) ? cleaner.clean(lines) : cleaner.call(lines)
      frozen_copy(cleaned) if cleaned.is_a?(Array) && !cleaned.empty?
    rescue StandardError => e
      report(e)
      nil
    end
    private_class_method :cleaned_lines

    # Returns [Array<String>] a frozen copy of the lines, each a frozen copy too, which leaves the
    # supplied lines, such as the exception's own, unchanged. A cleaner can return
    # Thread::Backtrace::Location objects, or Strings of its own.
    def self.frozen_copy(lines)
      lines.map { |line| String.new(line.to_s).freeze }.freeze
    end
    private_class_method :frozen_copy

    # Reports an error raised by a cleaner to the internal logger, as text: given the exception
    # itself, the internal logger's formatter would ask the same cleaner to clean its backtrace.
    def self.report(exception)
      where = exception.backtrace&.first
      Logger.processor.logger.warn(
        "Backtrace cleaner raised #{Utils.exception_name(exception)}: #{Utils.exception_message(exception)}" \
        "#{" (#{where})" if where}, so the full backtrace is logged"
      )
    rescue StandardError
      nil
    end
    private_class_method :report
  end
end
