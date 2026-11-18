module SemanticLogger
  # Manage a collection of appenders.
  #
  # While the process exits, it also knows which of its appenders it skips: those without a queue of
  # their own whose destination failed meanwhile, and how many log messages each has not been given
  # since (see #process_exiting=).
  class Appenders < Concurrent::Array
    # An appender skipped while the process exits: the error with which its destination failed, and
    # the number of log messages it has not been given since it was last reported.
    Skipped = Struct.new(:exception, :discarded)
    private_constant :Skipped

    # No appender is skipped while the process is not exiting.
    NONE_SKIPPED = {}.freeze
    private_constant :NONE_SKIPPED

    attr_accessor :logger

    def initialize(logger = Processor.logger.dup)
      @logger      = logger
      @logger.name = self.class.name
      @exiting     = false
      @skipped     = {}.compare_by_identity
      super()
    end

    def add(**args, &)
      appender = SemanticLogger::Appender.factory(**args, &)

      stream = appender.respond_to?(:console_stream) && appender.console_stream
      if stream && console_streams.include?(stream)
        logger.warn "Ignoring attempt to add a second #{stream} console appender since it " \
                    "would result in duplicate console output."
        return
      end

      self << appender
      appender
    end

    # The console streams (:stdout and/or :stderr) already being written to by the existing appenders.
    def console_streams
      filter_map { |appender| appender.console_stream if appender.respond_to?(:console_stream) }
    end

    # Whether any of the existing appenders already output to the console?
    # I.e. Writes to stdout or stderr.
    def console_output?
      console_streams.any?
    end

    # Returns [Array<Hash>] operational statistics for each appender.
    #
    # Appenders that run asynchronously (see SemanticLogger::Appender::Async#stats) report
    # their queue size and processed/dropped/failed counts. Appenders that log inline on the
    # processor thread report only their name with `async: false`.
    def stats
      map do |appender|
        if appender.respond_to?(:stats)
          appender.stats
        else
          {name: appender.name, async: false}
        end
      end
    end

    # Write the log message to every appender that should log it. An appender that fails is
    # reported, and the others still write the message.
    #
    # While the process exits, an appender without a queue of its own is skipped once its
    # destination has failed, and the message counted as not given to it (see #process_exiting=).
    #
    # The values of the sensitive keys are first replaced, once, so that no appender writes them
    # (see SemanticLogger.sensitive_keys=).
    #
    # A stack overflow is not a failure of the appender but of the thread, which must not overflow
    # again: on macOS a second stack overflow on the same thread crashes Ruby. It is raised to the
    # processor running this thread instead, and the message goes to no further appenders.
    def log(log)
      redactor = SemanticLogger.redactor
      log.redact(redactor) if redactor
      skipped = skipped_appenders
      each do |appender|
        writing = appender.should_log?(log)
        next unless writing
        next skipped[appender].discarded += 1 if skipped.key?(appender)

        appender.log(log)
      rescue SystemStackError
        raise
      rescue Exception => e
        logger.error "Failed to log to appender: #{appender.name}", e
        skip_while_exiting(appender, e) if writing
      end
    end

    # Flush every appender. An appender that fails is reported, and the others are still flushed.
    #
    # While the process exits, an appender that is skipped (see #process_exiting=) is not flushed,
    # since its destination failed: it is reported instead, with the number of log messages it has
    # not been given since it was last reported.
    def flush
      skipped = skipped_appenders
      each do |appender|
        next report_skipped(appender, skipped[appender]) if skipped.key?(appender)

        logger.trace "Flushing appender: #{appender.name}"
        appender.flush
      rescue Exception => e
        logger.error "Failed to flush appender: #{appender.name}", e
      end
      logger.trace "All appenders flushed"
    end

    def close
      closed_appenders = []
      each do |appender|
        logger.trace "Closing appender: #{appender.name}"
        appender.flush
        appender.close
        closed_appenders << appender
      rescue Exception => e
        logger.error "Failed to close appender: #{appender.name}", e
      end
      # Delete appenders outside the #each above which prevents changes during iteration.
      closed_appenders.each { |appender| delete(appender) }
      logger.trace "All appenders closed and removed from appender list"
    end

    # After a fork, or a log rotation, reopen each appender. Called on the thread that writes to the
    # appenders: the worker thread of the main Processor, or the calling thread with sync!. An
    # appender added with async: true or in batches is asked to reopen, by its own worker thread
    # (see Appender::Async#reopen).
    def reopen
      each do |appender|
        next unless appender.respond_to?(:reopen)

        logger.trace "Reopening appender: #{appender.name}"
        appender.reopen
      rescue Exception => e
        logger.error "Failed to re-open appender: #{appender.name}", e
      end
      logger.trace "All appenders re-opened"
    end

    # Tell each appender added with async: true or in batches whether the process is exiting: true
    # before the flush at exit, and false once it has returned (see QueueProcessor#process_exiting=).
    # Each one's queue processor is told straight away, rather than through the queue of the thread
    # that writes to every appender, which can be held up handing an entry to the full queue of an
    # appender whose worker thread is backing off during an outage. Takes no lock, so that it can be
    # called from any thread, or a signal trap. An appender that raises is reported, as for #flush,
    # and the others are still told, so that the flush at exit still runs.
    #
    # The appenders without a queue of their own are written to here, one log message after another,
    # by the thread that writes to every appender, so that during an outage the flush at exit would
    # wait while each message queued ahead of it failed in turn, up to a timeout each against a
    # server that does not answer. So while the process exits, once the destination of such an
    # appender fails, other than for the content of a message (see Subscriber#message_error?), it is
    # skipped until the process no longer exits: #log gives it no more messages, counting them, and
    # #flush reports them instead of flushing it. The other appenders are still given every message.
    def process_exiting=(exiting)
      @skipped = {}.compare_by_identity if exiting
      @exiting = exiting
      each do |appender|
        appender.process_exiting = exiting if appender.respond_to?(:process_exiting=)
      rescue Exception => e
        logger.error "Failed to tell appender that the process is exiting: #{appender.name}", e
      end
    end

    # After a fork, replace the queue and worker thread of each appender added with async: true or
    # in batches with the child's own, on the calling thread (see QueueProcessor#renew_after_fork).
    # Takes no lock, so that it can be called from a signal trap.
    def renew_after_fork
      each { |appender| appender.renew_after_fork if appender.respond_to?(:renew_after_fork) }
    end

    private

    # Returns [Hash] the appenders skipped while the process exits, by appender, or none while it does
    # not. The process can stop exiting while the thread that writes to every appender fails to write
    # to one, so one skipped then is left out until the process exits again, which starts afresh.
    def skipped_appenders = @exiting ? @skipped : NONE_SKIPPED

    # While the process exits, skip an appender without a queue of its own once writing to it failed
    # because of its destination (see #process_exiting=). An appender with a queue of its own is told
    # that the process is exiting, and handles it itself.
    def skip_while_exiting(appender, exception)
      return unless @exiting
      return if appender.respond_to?(:process_exiting=)
      return if appender.respond_to?(:message_error?) && appender.message_error?(exception)

      @skipped[appender] = Skipped.new(exception, 0)
    end

    # Report the log messages that a skipped appender has not been given since it was last reported.
    def report_skipped(appender, skipped)
      return if skipped.discarded.zero?

      logger.error "Discarded #{skipped.discarded} log message(s) during the flush at exit, after the " \
                   "destination failed, for appender: #{appender.name}", skipped.exception
      skipped.discarded = 0
    end
  end
end
