module SemanticLogger
  # A copy of the internal logger, named after whatever reports to it, such as an appender. It
  # follows the internal logger: once that is replaced (see SemanticLogger.internal_logger=), the next
  # report goes to a copy of the new one, so that replacing it takes effect on the running processor
  # and on the appenders already added.
  #
  # Safe to use from any thread and from a signal trap: it takes no lock. Two threads that find the
  # internal logger replaced at once each make a copy, and either one is kept.
  class InternalLoggerCopy
    # Parameters
    #   name: [String]
    #     The name of the copy, that of whatever reports to it.
    #   source: [#logger]
    #     Answers the internal logger to copy, such as SemanticLogger::Processor.
    def initialize(name, source)
      @name   = name
      @source = source
      # The internal logger and its copy, held as one frozen pair, so that a thread never sees the
      # copy of one internal logger next to another.
      @copied = nil
    end

    # Returns [true|false] whether the logger is the copy that #logger returns now, such as one that
    # was saved from it to be set back later, which then still follows the internal logger.
    def copy?(logger)
      copied = @copied
      !copied.nil? && copied.last.equal?(logger)
    end

    # Returns the copy of the internal logger as it is now, making a new one when it was replaced.
    def logger
      internal = @source.logger
      copied   = @copied
      return copied.last if copied&.first.equal?(internal)

      copy      = internal.clone
      copy.name = @name
      @copied   = [internal, copy].freeze
      copy
    end
  end
end
