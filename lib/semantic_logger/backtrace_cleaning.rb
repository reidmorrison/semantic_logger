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

    # Returns [Array<String>] the backtrace as the cleaner cleans it, frozen.
    #
    # Returns the supplied backtrace instead when the cleaner leaves out every line, so that the
    # only clue to where an exception came from is never lost, for example an exception raised
    # entirely within gems that a cleaner silences. Also when the cleaner does not return an Array,
    # or raises, so that a cleaner cannot stop a log entry being written.
    #
    # The cleaner is given a copy of the backtrace, which it may change, since the supplied one
    # belongs to the exception, and other appenders, such as error services, also read it.
    def self.clean(backtrace, cleaner)
      return backtrace if backtrace.nil? || backtrace.empty?

      lines   = backtrace.dup
      cleaned = cleaner.respond_to?(:clean) ? cleaner.clean(lines) : cleaner.call(lines)
      return backtrace unless cleaned.is_a?(Array) && !cleaned.empty?

      # A cleaner can return Thread::Backtrace::Location objects.
      cleaned.map(&:to_s).freeze
    rescue StandardError
      backtrace
    end
  end
end
