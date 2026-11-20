# Loaded now rather than autoloaded, since .logger builds one on first use, which can be the first log
# call of the process, made in a signal trap, where Ruby does not allow a require.
require "semantic_logger/appender/io"
require "semantic_logger/metric/processor_methods"

module SemanticLogger
  # Thread that submits and processes log requests
  class Processor < Appender::Async
    include Metric::ProcessorMethods

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
      @appenders        = Appenders.new(self.class.logger.dup)
      # The appenders whose removal was handed over to the worker thread, and not yet done (see #remove),
      # kept here rather than only on the queue, which a forked child replaces. Takes no lock to change.
      @pending_removals = Concurrent::Array.new
      @pid              = ::Process.pid
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
    #
    # In a forked child, the removals handed over to the worker thread that it had not yet done in the
    # parent (see #remove) were on the parent's queue, which the child replaces. So they are handed
    # over again, to the child's worker thread, after the reopen: each such appender, reopened first,
    # then closes only what it built in the child. They count as pending (see #removal_pending?) just
    # before that, so a #remove of one meanwhile returns true while it is still listed, briefly.
    def reopen
      forked = @pid != ::Process.pid
      @pid   = ::Process.pid
      appenders.renew_after_fork
      super
      hand_over_pending_removals if forked
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
    # Called where it must not wait for the worker thread (see #current_thread_inside?), such as by an
    # appender added with async: true or in batches as it writes, removing itself or another one, it
    # hands the removal over to the worker thread without waiting (see QueueProcessor#hand_over), and
    # returns true, before the appender is closed. Between writes, never while it writes to the
    # appender, once it has written the log messages queued ahead, the worker thread closes the
    # appender, then removes it (see #close_removed). An appender that removed itself is closed once
    # its current write has returned, after the log messages queued for it.
    #
    # The appender stays in the list until it is closed, so that the thread of an appender that
    # removed itself still counts as one that must not wait while it is being closed, and a close of
    # every appender (see #close) that runs first closes it instead. A removal handed over is never
    # what changes the list while the worker thread goes through it, writing a message or closing
    # every appender, since the worker thread itself takes the appender off the list. Until then,
    # #appenders still lists it.
    #
    # Called on any other thread for an appender whose removal was handed over and is not yet done,
    # it leaves the close to that removal, so that the appender is not closed twice: it waits for the
    # log messages queued ahead to be written (see #flush), which, with the removal queued ahead, takes
    # it off the list, and returns true. Not in a forked child that has not reopened this processor,
    # whose queue still holds none of those removals (see #removal_pending?): it closes the appender.
    #
    # Takes no lock, so that it can be called from a signal trap.
    def remove(appender)
      return hand_over_removal(appender) if current_thread_inside?
      return flush || true if removal_pending?(appender)

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
      return super unless current_thread_inside?

      refuse_on_appender_thread(:flush)
    end

    # Flush and close the appenders, then remove them (see Appenders#close).
    #
    # Returns false at once on the worker thread of an appender added with async: true or in batches,
    # as #flush does.
    def close
      return super unless current_thread_inside?

      refuse_on_appender_thread(:close)
    end

    # Returns [true|false] whether the calling thread must not wait for a thread that uses this
    # processor, since that thread may be waiting for it: the calling thread is the worker thread of
    # an appender added with async: true or in batches, for which the worker thread of this processor
    # waits, to flush or close it, or for room on its full queue. A message that such a thread logs
    # while the queue of this processor is full is dropped, rather than wait for room, only while
    # this processor's worker thread can be waiting for it: while that appender's own queue is full,
    # or a flush or close of it is waiting (see QueueProcessor#holding_up?).
    #
    # Otherwise false: holding no lock while it queues an entry, this processor never has another
    # thread wait for the calling thread to return from a call to it, even on its own worker thread.
    def current_thread_inside?
      appenders.worker_thread?
    end

    # Start the appender thread
    def start
      return false if active?

      thread
      true
    end

    # Give the snapshot of metrics to the metric appenders, on the worker thread, between writes,
    # without waiting for it (see Appender::Async#log_metrics).
    #
    # Called on the worker thread itself, such as by an appender that removes a metric appender as it
    # writes (see Metric::Collector#removing), it gives them the snapshot at once, since nothing else
    # writes to them then, so that one being removed is given it before it is closed.
    def log_metrics(snapshot)
      return super unless processor.worker_thread?

      appenders.log_metrics(snapshot)
    end

    # Log the entry without waiting for room on the full queue (see QueueProcessor#log_aside), for an
    # appender that logs as it writes, or as it is flushed, such as Metric::Summary: it may run on the
    # worker thread itself, or on a thread that the worker thread waits for, so that waiting for room
    # would wait for ever.
    def log_aside(log)
      processor.log_aside(log)
    end

    # Returns [Integer] the number of log messages waiting on the main pipeline queue.
    def queue_size
      queue.size
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
        queue_size:     queue_size,
        capped:         capped?,
        max_queue_size: capped? ? max_queue_size : nil,
        thread_active:  active? || false,
        processed:      processed_count,
        dropped:        dropped_count,
        appenders:      appenders.stats
      }
    end

    private

    # Hand the removal of the appender over to the worker thread (see #remove), recording it as
    # pending until it is done.
    def hand_over_removal(appender)
      @pending_removals << appender unless @pending_removals.include?(appender)
      processor.hand_over { close_removed(appender) }
      true
    end

    # Whether the removal of the appender was handed over to the worker thread (see #remove), and is
    # not yet done. Only in the process that handed it over, or a forked child once #reopen has handed
    # it over again: until then, the queue of a forked child holds the parent's entries, which no
    # worker thread of the child runs.
    def removal_pending?(appender) = @pid == ::Process.pid && @pending_removals.include?(appender)

    # In a forked child, hand over again the removals pending in the parent (see #reopen), for the
    # appenders still listed.
    def hand_over_pending_removals
      @pending_removals.dup.each do |appender|
        next @pending_removals.delete(appender) unless appenders.include?(appender)

        processor.hand_over { close_removed(appender) }
      end
    end

    # Close the appender, then remove it from the list, on the worker thread, unless it is no longer
    # listed: a close of every appender (see #close), or another removal, already closed it. Its
    # removal is then no longer pending. Once a metric appender is removed, the collector is told, so
    # that it stops collecting when that was the last one (see Metric::Collector#check).
    #
    # Reports an error rather than raise it to the worker thread, as Appenders#close does, whatever
    # its class, since one that is not a StandardError would stop the worker thread for good. Except
    # a stack overflow, which the worker thread must not carry on after: on macOS a second one on the
    # same thread crashes Ruby. It is raised, and a new worker thread carries on (see
    # QueueProcessor#run_command).
    def close_removed(appender)
      return @pending_removals.delete(appender) unless appenders.include?(appender)

      begin
        appender.close
      rescue SystemStackError
        raise
      rescue Exception => e
        appenders.logger.error "Failed to close appender: #{appender.name}", e
      ensure
        appenders.delete(appender)
        @pending_removals.delete(appender)
        Metric.collector.check if appender.metrics_interval
      end
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
