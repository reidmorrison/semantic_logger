require "semantic_logger/queue_processor/request"
require "semantic_logger/queue_processor/throttled_counter"
require "semantic_logger/queue_processor/reporter"
require "semantic_logger/queue_processor/backoff"
require "semantic_logger/queue_processor/inbox"
require "semantic_logger/queue_processor/held_write"
require "semantic_logger/queue_processor/reopener"

module SemanticLogger
  # Internal class that processes log messages from a queue on a separate thread.
  #
  # Internal use only: it owns the worker thread and the in-memory queue that back the
  # asynchronous appender proxy (SemanticLogger::Appender::Async). It is never returned to
  # application code.
  #
  # Supports two processing modes, selected by the `batch:` option:
  #   * Streaming (batch: false): each log message is written to the appender as it is dequeued.
  #   * Batching  (batch: true):  log messages are grouped and written via the appender's #batch
  #                               method, either once batch_size messages have accumulated, or
  #                               batch_seconds have elapsed since the previous batch.
  class QueueProcessor
    # Internal: seconds that #reopen waits for a worker thread that has stopped to end.
    STOPPED_WORKER_WAIT_SECONDS = 0.1

    attr_accessor :lag_check_interval, :lag_threshold_s, :dropped_message_report_seconds,
                  :batch_size, :batch_seconds, :non_blocking
    attr_reader :appender, :signal, :processed_count

    # Create a new processor and start its worker thread.
    def self.start(**args) = new(**args).tap(&:thread)

    # Parameters:
    #   appender: [SemanticLogger::Subscriber]
    #     The appender to forward log messages to from the worker thread.
    #
    #   max_queue_size: [Integer]
    #     The maximum number of log messages to hold on the queue before blocking attempts to add to the queue.
    #     -1: The queue size is uncapped and will never block no matter how long the queue is.
    #     Default: 10,000
    #
    #   lag_threshold_s: [Float]
    #     Log a warning when a log message has been on the queue for longer than this period in seconds.
    #     Default: 30
    #
    #   lag_check_interval: [Integer]
    #     Number of messages to process before checking for slow logging.
    #     Default: 1,000
    #     Note: Not applicable when batch: true.
    #
    #   batch: [true|false]
    #     Process log messages in batches via the appender's #batch method.
    #     Default: false
    #     Note: The appender must implement #batch.
    #
    #   batch_size: [Integer]
    #     Maximum number of messages to batch up before sending.
    #     Default: 300
    #     Note: Only applicable when batch: true.
    #
    #   batch_seconds: [Integer]
    #     Maximum number of seconds between sending batches.
    #     Default: 5
    #     Note: Only applicable when batch: true.
    #
    #   non_blocking: [true|false]
    #     Whether to drop log messages instead of blocking the calling thread when the queue is full.
    #     Only applies to a capped queue.
    #     Default: false
    #
    #   dropped_message_report_seconds: [Integer]
    #     Log the count of messages dropped because the queue was full, with non_blocking or once
    #     the worker thread has stopped (see async_max_retries), to the internal logger at most once
    #     every this number of seconds. Also limits how often messages discarded because they could
    #     not be written are reported, after the first.
    #     Default: 30
    #
    #   async_max_retries: [Integer]
    #     Maximum number of consecutive times to restart the worker thread after it raises an
    #     exception while processing messages. Each restart first sleeps for `retry_count` seconds
    #     (1s, then 2s, ...) as a back-off, unless a flush or close is waiting (see #flush), or the
    #     process is exiting (see #process_exiting=). Once this many consecutive retries are
    #     exhausted the thread stops instead of restarting. The counter resets to zero whenever a
    #     message is processed successfully. A message or batch that the destination failed is
    #     written again after the back-off when the appender says that the write wrote none of it
    #     (see Subscriber#wrote_nothing?), up to HeldWrite::MAX_RESENDS times after the destination
    #     answered with a failure, and is otherwise discarded.
    #     -1: Retry indefinitely and never stop the thread (the pre-v5 behaviour). The back-off
    #         still applies, and still resets after any successful message.
    #     A worker thread started again by #reopen in the same process carries on with the count, so
    #     that one that had used all its retries stops again at its first failure, rather than hold
    #     up the threads logging to it with a back-off as long again while the destination is still
    #     unavailable; one that stopped before, such as after a fatal exception, has the retries it
    #     had left. Only the worker thread of a child process, after a fork, starts counting afresh.
    #     Default: 100
    def initialize(appender:,
                   max_queue_size: 10_000,
                   lag_check_interval: 1_000,
                   lag_threshold_s: 30,
                   batch: false,
                   batch_size: 300,
                   batch_seconds: 5,
                   non_blocking: false,
                   dropped_message_report_seconds: 30,
                   async_max_retries: 100)
      @appender                       = appender
      @lag_check_interval             = lag_check_interval
      @lag_threshold_s                = lag_threshold_s
      @batch                          = batch
      @batch_size                     = batch_size
      @batch_seconds                  = batch_seconds
      @non_blocking                   = non_blocking
      @dropped_message_report_seconds = dropped_message_report_seconds
      @backoff                        = Backoff.new(async_max_retries)
      @thread                         = nil
      # Only batch mode parks the worker on the signal; streaming mode never touches it.
      @signal                         = Concurrent::Event.new if batch
      @reporter                       = Reporter.new(appender)
      @reopener                       = Reopener.new(appender, @reporter)
      @processed_count                = 0
      @inbox                          = Inbox.new(max_queue_size)
      @held                           = HeldWrite.new

      return unless batch? && !appender.respond_to?(:batch)

      raise(ArgumentError, "#{appender.class.name} does not support batching. It must implement #batch")
    end

    # Internal logger used to report problems encountered while processing log messages.
    def logger = @reporter.logger

    # Returns [Integer] the maximum number of consecutive retries after a failure (see #initialize).
    def async_max_retries = @backoff.max_retries

    # Returns [Integer] the number of consecutive failures, since a message was last processed.
    def retry_count = @backoff.retry_count

    # Returns [Thread] the worker thread.
    #
    # Starts the worker thread if it is not currently running. It carries on with the count of
    # failures in a row (see async_max_retries).
    def thread
      return @thread if @thread&.alive?

      spawn_worker
    end

    # Returns [true|false] whether the worker thread is running.
    def active? = @thread&.alive?

    # Returns [Queue|SizedQueue] the queue of log messages and requests waiting for the worker thread.
    def queue = @inbox.queue

    # Returns [Integer] the most entries the queue holds, or -1 for no limit.
    def max_queue_size = @inbox.max_queue_size

    # Returns [true|false] whether the queue has a capped size.
    def capped? = @inbox.capped?

    # Returns [true|false] whether messages are dropped instead of blocking when the queue is full.
    # Only a capped queue can drop messages.
    def non_blocking? = @non_blocking && capped?

    # Returns [Integer] the number of log messages dropped because the queue was full.
    def dropped_count = @reporter.dropped_count

    # Returns [Integer] the number of log messages discarded because they could not be written,
    # whether their content or the destination was at fault (see Subscriber#message_error?).
    def failed_count = @reporter.failed_count

    # Returns [true|false] whether messages are processed in batches.
    def batch? = @batch

    # Returns [true|false] whether the worker thread gave up after an error, so that queued
    # messages are no longer being processed.
    def stopped? = @stopped == true

    # Add a log message to the queue for processing.
    #
    # When non-blocking and the queue is full, the message is dropped instead of blocking the
    # calling thread, and the count of dropped messages is reported periodically.
    #
    # Once the worker thread has stopped for good (see async_max_retries), nothing will empty the
    # queue, so messages are also dropped instead of blocking the calling thread forever. That
    # includes a message already waiting for room on the full queue when the worker thread stops.
    def log(log)
      enqueued = @inbox.push(log, wait: !(non_blocking? || stopped?)) { !stopped? }
      # Reported at most once every dropped_message_report_seconds, with whether it was dropped
      # because the worker thread has stopped for good.
      @reporter.dropped(max_queue_size, stopped: stopped?, interval: dropped_message_report_seconds) unless enqueued

      # For batches wake up the processing thread once the number of queued messages has been
      # exceeded. Also wake it on a drop so it drains the full queue rather than waiting out the
      # batch interval.
      signal.set if batch? && (queue.size >= batch_size)

      enqueued
    end

    # Flush all queued log entries to the appender.
    #  All queued log messages are written and then the appender is flushed.
    #
    # A flush or close does not wait out back-offs after the destination failed, nor each message
    # ahead of it failing in turn: submitting it ends the back-off under way, and until it has run, a
    # message or batch that the destination fails is discarded, rather than written again after a
    # back-off, and so are the messages queued after that one, ahead of the flush or close, without
    # being written (see Backoff#give_up?).
    def flush
      submit_request(:flush)
    end

    # Flush any outstanding messages and close the appender.
    def close
      submit_request(:close)
    end

    # Tell the worker thread whether the process is exiting, before and after the flush at exit
    # (see Backoff#exiting=). While it is, the worker thread acts as though a flush were waiting
    # (see #flush), already before the flush at exit reaches this queue: it stops backing off and
    # writing again what the destination failed, and once the destination fails, discards the
    # messages queued ahead of the next request, such as the flush at exit, so that the process exits
    # promptly during an outage. Takes no lock, so that it can be called from any thread, or a signal
    # trap.
    def process_exiting=(exiting)
      @backoff.exiting = exiting
    end

    # Reopen the appender, on the worker thread, and the queue and worker thread after a fork (see
    # #renew_after_fork), or start the worker thread again within the same process once it has ended
    # or stopped.
    #
    # The worker thread reopens the appender before it next takes messages off the queue, or writes
    # again the ones it holds (see Reopener), so that it is never reopened while it is writing, and
    # this returns before it has. After a fork, the reopen is asked for before the child's new worker
    # thread starts, so that it reopens the appender before it writes anything. To wake up a
    # streaming worker thread waiting for the next message, :reopen is added to the queue, without
    # waiting for room: one that is not waiting has messages to write, and reopens the appender before
    # them. A batching worker thread is not woken up, since that would write a partial batch, so
    # nothing is added to its queue: it reopens the appender at its next batch, at most batch_seconds
    # later, or when a flush or close wakes it up, before running them.
    #
    # Within the same process, such as after a log rotation, the queue and its entries are kept, and
    # so is the worker thread while it runs (see #thread). It writes the queued entries in order,
    # starting with one it has already taken off the queue, and no other thread writes to the
    # appender meanwhile. A worker thread that has ended is replaced by one that carries on with the
    # queued entries, and with the count of failures in a row (see async_max_retries). So is one that
    # has stopped (see #stopped?), which may still be reporting that it stopped: it is given a moment
    # to end first, so that its report comes before the new thread's. A worker thread that has
    # stopped no longer writes to the appender, nor changes the state of this processor, so none that
    # was replaced can change it once a new one has started.
    #
    # Also called from a signal trap, such as one that reopens the log files after a rotation, where
    # Ruby does not allow a Mutex to be locked, so it takes none: it uses only Queue and Thread
    # methods, which Ruby allows there.
    def reopen
      @reopener.ask
      renew_after_fork
      @inbox.push(:reopen, wait: false) unless batch?
      restart_worker
    end

    # After a fork, the queue holds the entries that the parent process had queued, which the
    # parent's worker thread writes, so the child starts again with an empty queue and a worker
    # thread of its own, rather than write them a second time. Does nothing in the process that
    # created the queue. Asks for no reopen of the appender: #reopen asks before it calls this.
    #
    # Called on the thread that reopens after the fork, which takes no lock (see #reopen). Called
    # by Processor#reopen, through Appenders#renew_after_fork, before the appender is asked to
    # reopen: the new worker thread has nothing to write until the processor's worker thread, which
    # asks first, hands it entries.
    def renew_after_fork
      return unless @inbox.forked?

      # Workaround CRuby crash on fork by recreating queue on reopen
      #   https://github.com/reidmorrison/semantic_logger/issues/103
      @inbox.recreate
      # The parent process writes the messages it held to write again.
      @held.release
      @thread&.kill if @thread&.alive?
      # A worker thread new to this process, which has not failed to write yet.
      @backoff.restart
      spawn_worker
    end

    private

    # Start a new worker thread, as @thread. It carries on with the count of failures in a row,
    # including one taking over from a thread that overflowed its stack (see #process).
    #
    # The new thread waits until it has been assigned to @thread before it takes anything off the
    # queue. Otherwise it could overflow its stack and hand over to another new thread before then,
    # and the thread that started it would then assign it, after it has ended, leaving the one it
    # handed over to running unseen beside the next one that #thread starts. It waits on a Queue,
    # whose #push Ruby allows in a signal trap (see #reopen).
    def spawn_worker
      @stopped        = false
      @stack_overflow = nil
      assigned        = Queue.new
      @thread         = Thread.new do
        assigned.pop
        name_worker
        process
      end
      assigned << true
      @thread
    end

    # Start the worker thread again within the same process, unless it is running (see #reopen).
    #
    # A worker thread that has stopped (see #stopped?) may still be reporting that it stopped, so it
    # is given a moment to end first. Then a new one is started, whether it has ended or not.
    def restart_worker
      return thread unless stopped?

      @thread&.join(STOPPED_WORKER_WAIT_SECONDS)
      spawn_worker
    end

    # Name the worker thread after its appender, such as "SL File", short enough for tools that
    # list threads, such as `top -H`, to tell the workers apart: Linux keeps only the first 15 bytes.
    # The name is only a label, so when Ruby rejects it, for example for a class given a temporary
    # name with a NUL byte, the thread carries on without one.
    def name_worker
      Thread.current.name = ["SL", appender.class.name&.split("::")&.last].compact.join(" ")
    rescue StandardError
      nil
    end

    # Separate thread for processing log messages.
    #
    # This thread is designed to never go down unless the main thread terminates or the appender is
    # closed. A StandardError while processing restarts the processing, after a back-off, up to
    # async_max_retries times. Any other exception, even one from the first report, stops this
    # processor, which then drops new messages, rather than ending the thread and leaving the
    # calling threads blocked on a full queue.
    #
    # A flush or close that is waiting (see #flush), or the process exiting (see #process_exiting=),
    # does not wait out a back-off, so processing then restarts straight away, without counting a
    # retry, and discards the messages queued ahead of the next request without writing them (see
    # Backoff#give_up?).
    def process
      safe_log(:trace, "Async: Appender thread active")
      begin
        resend_held if reopen_appender
        carry_on = @stack_overflow || (batch? ? process_messages_in_batches : process_messages)
      rescue StandardError => e
        retry if @backoff.give_up?(e)
        if @backoff.retry?
          safe_log(:warn, "Async: Restarting due to exception, retry #{retry_count} of #{@backoff.limit}, " \
                          "sleeping #{retry_count}s", e)
          @backoff.wait
          retry
        end

        @stopped = true
        discard_held(e)
        safe_log(:error, "Async: Stopping after #{retry_count} failed retries, dropping new messages", e)
      end
    rescue Exception => e
      @stopped = true
      discard_held(e)
      safe_log(:error, "Async: Stopping due to fatal exception", e)
    ensure
      # A thread that overflowed its stack hands the queue over to a new one (see #stack_overflowed).
      # It is still the worker thread, since #reopen replaces only one that has ended or stopped, and
      # one that overflowed has neither. Any other thread leaves @thread as it is, since one that has
      # ended reads as inactive.
      spawn_worker if carry_on
      safe_log(:trace, "Async: Thread has stopped") unless carry_on
    end

    # Report to the internal logger, ignoring any error (see Reporter#log).
    def safe_log(level, message, exception = nil) = @reporter.log(level, message, exception)

    # Streaming: write each log message to the appender as it is dequeued.
    #
    # Returns true when processing must carry on in a new thread (see #stack_overflowed).
    def process_messages
      count = 0
      while reopen_appender && (message = queue.pop)
        if message.is_a?(Log)
          gave_up = @backoff.gave_up
          next messages_failed([message], gave_up) if gave_up

          write_message(message)
          return true if @stack_overflow

          @backoff.reset
          count += 1
          # Check every few log messages whether this appender thread is falling behind
          if count > lag_check_interval
            check_lag(message)
            count = 0
          end
        elsif message.is_a?(Request)
          break unless run_command(message)
        end
        # Otherwise :reopen, which #reopen adds to wake up this thread to reopen the appender.
      end
      return true if @stack_overflow

      safe_log(:trace, "Async: Queue Closed")
      false
    end

    # Batching: group up log messages before writing them via the appender's #batch method.
    #
    # Once the destination failed while the worker thread was waited on (see Backoff#gave_up), the
    # messages taken off the queue ahead of the first request, such as a flush, are discarded without
    # being written, and those taken off the queue after it are written as a batch, as usual.
    #
    # Returns true when processing must carry on in a new thread (see #stack_overflowed).
    def process_messages_in_batches
      loop do
        # Wait for batch interval or number of messages to be exceeded.
        signal.wait(batch_seconds)

        # Counted before the appender is reopened, so that a flush or close counted here, and so run
        # in this batch, comes after the reopen asked for before it.
        message_count = queue.length
        return true unless reopen_appender

        logs          = []
        commands      = []
        discarded     = []
        gave_up       = @backoff.gave_up
        first         = true
        message_count.times do
          # Queue#pop(true) raises an exception when there are no more messages, which is considered expensive.
          message = queue.pop
          if message.is_a?(Log)
            next discarded << message if gave_up && commands.empty?

            logs << message
            if first
              check_lag(message)
              first = false
            end
          elsif message.is_a?(Request)
            commands << message
          end
        end
        messages_failed(discarded, gave_up) unless discarded.empty?
        # Stop processing once a command (e.g. :close) signals the thread to terminate.
        return false unless write_batch_then_run(logs, commands)
        return true if @stack_overflow

        signal.reset unless queue.size >= batch_size
      end
    end

    # Write the log messages taken off the queue as a batch, then run the commands taken off the
    # queue with them. Returns false once a command (:close) stops processing.
    #
    # When the batch cannot be written, for example because the destination is unavailable, the
    # messages not yet written are held to be written again after the back-off, or discarded and
    # counted as failed (see #not_written). The commands still run before the error propagates to
    # #process to back off. Otherwise they would be lost, and a caller waiting on #flush or #close,
    # such as the flush at exit, would wait forever. Since they are waiting, the messages are then
    # discarded rather than held. A command behind a close is not run, and so no longer waits.
    def write_batch_then_run(logs, commands)
      accounted = processed_count + failed_count
      unless logs.empty?
        write_batch(logs)
        @backoff.reset
      end
      commands.all? { |command| run_command(command) }
    rescue StandardError => e
      # Every message taken off the queue was written or already discarded, except those still
      # to be written when the error was raised: the last ones, since a batch is written in order.
      # The write that raised wrote none of them, if the appender says so, and the rest were not
      # sent at all.
      unwritten = logs.size - (processed_count + failed_count - accounted)
      not_written(logs.last(unwritten), e, hold: commands.empty?) if unwritten.positive?
      # The commands run once the batch is written, until one raises: the last one that ran, if any.
      failed = commands.select(&:ran?).last
      raise e if commands.all? { |command| process_message_after_failure(command) }

      message = failed ? "Failed to #{failed.command} the appender" : "Closed without writing #{unwritten} log messages"
      safe_log(:warn, "Async: #{message}", e)
      false
    ensure
      commands.each(&:done)
    end

    # Run a command after a batch could not be written, unless it has run already, such as a flush
    # that raised. Returns false once a command (:close) stops processing, even when the command
    # itself fails.
    def process_message_after_failure(command)
      return command.command != :close if command.ran?

      run_command(command)
    rescue StandardError => e
      safe_log(:warn, "Async: Failed to #{command.command} the appender", e)
      command.command != :close
    end

    # Run a command taken off the queue on the appender, reporting one it does not know. Returns
    # false once message processing must stop (:close).
    def run_command(request)
      request.run(appender) do |command|
        safe_log(:warn, "Async: Appender thread: Ignoring unknown command: #{command}")
      end
    end

    # Reopen the appender, if asked to (see #reopen), before taking more messages off the queue, or
    # writing again the ones held, so that it is never reopened while it is writing, and a stack
    # overflow while it reopens is charged to none of them. Returns false once the stack has
    # overflowed: this thread then takes nothing more off the queue, and a new one carries on (see
    # #stack_overflowed), which writes them.
    def reopen_appender = !(@stack_overflow ||= @reopener.reopen_if_asked)

    # Write one log message to the appender.
    #
    # A message whose content cannot be written (see #message_error?) is discarded and reported,
    # and the thread carries on with the next message. Any other error, such as the destination
    # being unavailable, propagates to #process, which backs off before writing the message again,
    # or before carrying on with the next one, having discarded it (see #not_written). A stack
    # overflow discards the message too (see #stack_overflowed).
    def write_message(log)
      appender.log(log)
      @processed_count += 1
    rescue SystemStackError => e
      stack_overflowed([log], e)
    rescue StandardError => e
      return messages_failed([log], e) if message_error?(e)

      not_written([log], e)
      raise e
    end

    # Write the log messages to the appender as a batch.
    #
    # When the content of a message cannot be written (see #message_error?), and the appender's
    # #batch is all or nothing, the batch is split in half and each half written separately, so
    # that only the offending message is discarded rather than every message in the batch.
    # Otherwise the batch is discarded, since writing it again could duplicate the messages that
    # the appender had already written. So it is, at once, when the appender says that the error is
    # one that would fail any batch, whatever messages it holds (see #fails_any_batch?). A stack overflow
    # discards the batch, and the rest of the batch being split, without splitting it further (see
    # #stack_overflowed).
    def write_batch(logs)
      return messages_failed(logs, @stack_overflow) if @stack_overflow

      appender.batch(logs)
      @processed_count += logs.size
    rescue SystemStackError => e
      stack_overflowed(logs, e)
    rescue StandardError => e
      raise unless message_error?(e)
      return messages_failed(logs, e) if logs.size == 1 || !appender.batch_all_or_nothing? || fails_any_batch?(e)

      logs.each_slice((logs.size + 1) / 2) { |half| write_batch(half) }
    end

    # Discard log messages whose writing overflowed the stack, for example a value nested too
    # deeply for a custom formatter. Retrying cannot write them, as for #message_error?.
    #
    # This thread must not overflow its stack again: on macOS a second stack overflow on the same
    # thread crashes Ruby. So nothing else is written on it, including the rest of a batch, which
    # is discarded rather than split up further to find the message at fault. Once any commands
    # taken off the queue with the messages have run, a new thread carries on (see #process).
    def stack_overflowed(logs, exception)
      @stack_overflow = exception
      messages_failed(logs, exception)
    end

    # Whether the appender says the exception was caused by the content of a log message, rather
    # than by the destination. An appender that cannot tell (it does not implement
    # #message_error?) has every error treated as the destination's, so the thread backs off.
    def message_error?(exception) = appender.respond_to?(:message_error?) && appender.message_error?(exception)

    # Whether the appender says that the write that raised the exception wrote none of the log
    # messages it was given. An appender that cannot tell (it does not implement #wrote_nothing?)
    # may have written some of them, so they are not written again.
    def wrote_nothing?(exception) = appender.respond_to?(:wrote_nothing?) && appender.wrote_nothing?(exception)

    # Whether the appender says that the write that raised the exception sent nothing to the
    # destination, such as when it could not connect, so that the destination has not answered it.
    # An appender that cannot tell (it does not implement #not_sent?) has every failure counted
    # towards HeldWrite::MAX_RESENDS.
    def not_sent?(exception) = appender.respond_to?(:not_sent?) && appender.not_sent?(exception)

    # Whether the appender says that the exception, a message error, would fail any batch, whatever
    # messages it holds, so that splitting the batch cannot find messages at fault. An appender that
    # does not implement #fails_any_batch? has every all or nothing batch split, as before it could say.
    def fails_any_batch?(exception) = appender.respond_to?(:fails_any_batch?) && appender.fails_any_batch?(exception)

    # Log messages that the destination kept from being written. They are held to be written again
    # once the thread has backed off (see #process), when the appender says that the write wrote
    # none of them, up to HeldWrite::MAX_RESENDS times after the destination answered with a failure
    # (a write it never received, see #not_sent?, is not counted). Otherwise they are discarded and
    # counted as failed, since writing them again could write some of them twice, or has failed every
    # time. So they are while a flush or close is waiting, such as one taken off the queue with them
    # (`hold: false`), which must not wait for them to be written again, or the process is exiting.
    def not_written(logs, exception, hold: true)
      hold &&= wrote_nothing?(exception) && !@backoff.waited_on?
      return if hold && @held.hold(logs, answered: !not_sent?(exception))

      messages_failed(logs, exception)
    end

    # Write the log messages held after the destination failed (see #not_written) again, ahead of
    # those still on the queue, as they were written: as a batch when batching. When that fails as
    # well, they are held again, or discarded once the destination has answered them with a failure
    # after they were written again HeldWrite::MAX_RESENDS times, and the error propagates to
    # #process, which backs off before carrying on.
    def resend_held
      @held.resend do |logs|
        batch? ? write_batch_then_run(logs, []) : write_message(logs.first)
        @backoff.reset
      end
    end

    # Discard the log messages held to be written again, if any, once they will not be.
    def discard_held(exception) = @held.release&.then { |logs| messages_failed(logs, exception) }

    # Record log messages discarded because they could not be written, whether their content or
    # the destination was at fault, reported at most once every dropped_message_report_seconds
    # after the first (see Reporter#failed).
    def messages_failed(logs, exception)
      @reporter.failed(logs, exception, interval: dropped_message_report_seconds)
    end

    # Report when the log message taken off the queue has waited longer than lag_threshold_s.
    def check_lag(log) = @reporter.lag(log, lag_threshold_s, queue.size)

    # Add the request to the queue, counted as waiting until it has run or will not (see Request#done),
    # so that the worker thread does not wait out back-offs meanwhile (see Backoff). Returns false
    # when it could not be added.
    def enqueue_request(request, submitted_to)
      @backoff.request_submitted
      added = @inbox.push(request, submitted_to, wait: true) { active? && !stopped? }
    ensure
      request.done unless added
    end

    # Submit a command to the worker thread and wait for the reply.
    #
    # Returns false, without submitting it, when called on the worker thread itself, such as by an
    # appender that, as it writes, removes an appender, which flushes the processor first (see
    # SemanticLogger.remove_appender): the worker thread cannot run the command while it waits for
    # the reply, so it would wait forever.
    def submit_request(command)
      return false if !active? || @thread.equal?(Thread.current)

      @reporter.queued(queue.size, command)
      # Wake up the processing thread to process this command immediately.
      signal.set if batch?

      submitted_to = queue
      request      = Request.new(command) { @backoff.request_done }
      return false unless enqueue_request(request, submitted_to)

      # A reply can come while the request is on the current queue, which #reopen replaces, and a
      # worker thread is running it, which may be a new one after a stack overflow.
      request.wait { queue.equal?(submitted_to) && active? }
    end
  end
end
