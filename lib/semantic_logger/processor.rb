# Loaded now rather than autoloaded, since .logger builds one on first use, which can be the first log
# call of the process, made in a signal trap, where Ruby does not allow a require.
require "semantic_logger/appender/io"

module SemanticLogger
  # Thread that submits and processes log requests
  class Processor < Appender::Async
    # Allow the internal logger to be overridden from its default of $stderr
    #   Can be replaced with another Ruby logger or Rails logger, but never to
    #   SemanticLogger::Logger itself since it is for reporting problems
    #   while trying to log to the various appenders (raises ArgumentError)
    #
    # A Ruby or Rails logger is wrapped in an appender (see Appender.internal_logger), so .logger
    # returns that appender. The appenders added from then on report to it.
    def self.logger=(logger)
      @logger = Appender.internal_logger(logger)
    end

    # Internal logger for SemanticLogger
    #   For example when an appender is not working etc..
    #   By default logs to $stderr
    def self.logger
      @logger ||=
        begin
          l      = SemanticLogger::Appender::IO.new($stderr, level: :warn)
          l.name = name
          l
        end
    end

    attr_reader :appenders

    def initialize(max_queue_size: 10_000)
      @appenders = Appenders.new(self.class.logger.dup)
      super(appender: @appenders, max_queue_size: max_queue_size)
    end

    # Reopen the appenders, after a fork or within the same process, each on the thread that writes
    # to it, between writes (see Appender::Async#reopen): the worker thread of this processor reopens
    # the appenders (see Appenders#reopen).
    #
    # After a fork, the queue and worker thread of each appender added with async: true or in batches
    # are first replaced on the calling thread, rather than once this processor's worker thread gets
    # to the reopen, so that they are running when this returns, such as for SemanticLogger.stats.
    # That worker thread still asks each of them to reopen its appender, ahead of the entries it
    # hands them. Takes no lock, so that it can be called from a signal trap.
    def reopen
      appenders.renew_after_fork
      super
    end

    # Remove the appender from those that this processor writes to, and close it. Returns the result
    # of closing it, or true when it hands the close over to the worker thread (see below).
    #
    # Before closing an appender that it removed, waits until the log messages already queued are
    # written to the other appenders, and those flushed (see #flush), so that none is still being
    # written to it when it is closed, such as a request on its connection that the worker thread is
    # sending.
    #
    # First, when the appender is one of them, and the appenders are to be reopened (see #reopen) but
    # the worker thread has not yet reopened them, such as in a forked child that has not logged
    # since the fork, waits until it has (see QueueProcessor#await_reopen), so that the appender is
    # reopened before it is removed. Its #close then closes only what it built in this process,
    # rather than what it inherited from the parent, which over TLS would end the parent's connection
    # too, for an appender whose #reopen forgets what the parent built, but whose #close does not. An
    # appender added with async: true or in batches is asked to reopen by that reopen, and its own
    # worker thread reopens it before it runs the close.
    #
    # Called on the worker thread itself, such as by an appender as it writes, it closes the appender
    # at once, without waiting, since nothing else writes to it then.
    #
    # Called on the worker thread of an appender added with async: true or in batches, such as by
    # that appender as it writes, removing itself or another one, it must not wait for the worker
    # thread of this processor, which may be waiting for it: to flush that appender, or for room on
    # its full queue. So it removes the appender at once, and hands the close over to the worker
    # thread of this processor without waiting (see QueueProcessor#hand_over), which closes it between
    # writes, never while it writes to it, once it has written the log messages queued ahead. Returns
    # true then, before the appender is closed. An appender that removed itself is closed once its
    # current write has returned, after the log messages queued for it.
    #
    # Takes no lock, so that it can be called from a signal trap.
    def remove(appender)
      return hand_over_close(appender) if appenders.worker_thread?

      processor.await_reopen if appenders.include?(appender)
      flush if appenders.delete(appender)
      appender.close
    end

    # Write the log messages already queued to the appenders, then flush them (see
    # QueueProcessor#flush).
    #
    # Returns false at once on the worker thread of an appender added with async: true or in batches,
    # such as by that appender as it writes, rather than wait forever: the worker thread of this
    # processor waits for that thread to flush the appender. Reported once to the internal logger.
    def flush
      return super unless appenders.worker_thread?

      refuse_on_appender_thread(:flush)
    end

    # Flush and close the appenders, then remove them (see Appenders#close).
    #
    # Returns false at once on the worker thread of an appender added with async: true or in batches,
    # as #flush does.
    def close
      return super unless appenders.worker_thread?

      refuse_on_appender_thread(:close)
    end

    # Returns [true|false] whether the calling thread must not wait for a thread that uses this
    # processor, since that thread may be waiting for it: the calling thread is the worker thread of
    # an appender added with async: true or in batches, for which the worker thread of this processor
    # waits, to flush it, or for room on its full queue. Otherwise false: holding no lock while it
    # queues an entry, this processor never has another thread wait for the calling thread to return
    # from a call to it, even on its own worker thread.
    def current_thread_inside?
      appenders.worker_thread?
    end

    # Start the appender thread
    def start
      return false if active?

      thread
      true
    end

    # Returns [Hash] operational statistics for the logging pipeline.
    #
    #   queue_size:     [Integer] Number of log messages waiting on the main pipeline queue.
    #   capped:         [Boolean] Whether the main queue has a maximum size.
    #   max_queue_size: [Integer] Maximum queue size, or nil when uncapped.
    #   thread_active:  [Boolean] Whether the main pipeline thread is running.
    #   processed:      [Integer] Cumulative number of log messages processed since startup.
    #   dropped:        [Integer] Cumulative number of log messages dropped at the main queue.
    #   appenders:      [Array<Hash>] Per-appender statistics, see Appenders#stats.
    def stats
      {
        queue_size:     queue.size,
        capped:         capped?,
        max_queue_size: capped? ? max_queue_size : nil,
        thread_active:  active? || false,
        processed:      processed_count,
        dropped:        dropped_count,
        appenders:      appenders.stats
      }
    end

    private

    # Remove the appender, and hand its close over to the worker thread (see #remove).
    def hand_over_close(appender)
      appenders.delete(appender)
      processor.hand_over { close_removed(appender) }
      true
    end

    # Close an appender that was removed, on the worker thread, reporting an error rather than raise
    # it to the worker thread, as Appenders#close does.
    def close_removed(appender)
      appender.close
    rescue StandardError => e
      appenders.logger.error "Failed to close appender: #{appender.name}", e
    end

    # Refuse to flush or close on the worker thread of an appender (see #flush), and report it the first
    # time. Returns false.
    def refuse_on_appender_thread(command)
      unless @refused_on_appender_thread
        @refused_on_appender_thread = true
        appenders.logger.warn "SemanticLogger.#{command} was called on the worker thread of an appender " \
                              "added with async: true or in batches, such as by that appender as it writes. " \
                              "It returns false there, without waiting, since the processor's thread waits " \
                              "for that thread. Reported only once."
      end
      false
    end
  end
end
