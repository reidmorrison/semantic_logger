module SemanticLogger
  # Internal, experimental: in the main Ractor, receives the log entries logged in other Ractors and
  # hands them to the processor, which writes them to the appenders. Ruby 4.0 and later only.
  #
  # It knows the port that the other Ractors send to (see RactorProcessor), and runs the thread in
  # the main Ractor that receives from it. The thread starts with the processor's thread, when an
  # appender is added. Entries sent before then wait on the port.
  #
  # Ruby 4.0 can crash, or hang, a forked child process that uses a port, when a thread of the parent
  # was waiting on a port at the time of the fork. So no thread of the main Ractor other than the
  # receiving thread ever waits on a port: a thread that waits for the receiving thread, such as one
  # flushing, waits on a Queue instead. And the receiving thread itself waits on a Queue while the
  # process forks (see .pause).
  #
  # A thread that waits for the receiving thread hands it that Queue without locking a Mutex, so that
  # it can do so in a signal trap, such as one that forks or flushes, where Ruby does not allow one to
  # be locked.
  module RactorReceiver
    # Seconds that .pause waits for the receiving thread to finish the entry it is handing over.
    PAUSE_TIMEOUT = 5

    # Seconds that .pause waits at a time for the receiving thread to get to the pause, before it checks
    # again. Ruby does not end a wait on a Queue that a signal trap interrupted when the Queue is closed
    # while the trap runs, until the wait times out; the receiving thread does that when it gets to a
    # pause that a pause in the trap shares.
    PAUSE_CHECK_SECONDS = 0.1

    # The thread variable that holds, while a thread pauses the receiving thread, the Queue that the
    # receiving thread closes once it waits for the fork to be over (see .pause).
    PAUSING = :semantic_logger_pausing_ractor_receiver

    @port       = ::Ractor::Port.new
    @pid        = ::Process.pid
    @thread     = nil
    # Whether the receiving thread was started, so that .reopen starts it again in a child process.
    @started    = false
    # The pid of the process whose receiving thread runs, or nil when none runs.
    @running    = nil
    # The Queues that threads of the main Ractor wait on for the receiving thread, each with its token,
    # in the order they were registered. Only the receiving thread takes them off.
    @waits      = Queue.new
    # The Queues that the receiving thread took off @waits before it got to their token. Only the
    # receiving thread, or .reopen in a child process, uses it.
    @registered = {}
    @mutex      = Mutex.new

    class << self
      # Returns [Ractor::Port] where other Ractors send their log entries and requests. Any Ractor
      # can read it, since a port is shareable.
      attr_reader :port

      # Returns [true|false] whether a receiving thread runs in this process. Any Ractor can read it.
      def running?
        @running == ::Process.pid
      end

      # Starts the receiving thread, unless it is running.
      def start
        @mutex.synchronize do
          return false if @thread&.alive?

          port     = @port
          @started = true
          @running = ::Process.pid
          @thread  = Thread.new do
            Thread.current.name = "SL Ractors"
            receive(port)
          ensure
            @running = nil
          end
        end
        true
      end

      # Restarts the receiving thread, if it was started: in the child process after a fork, which the
      # thread does not survive, or after it stopped. The child also gets a new port, since the port it
      # inherited still holds the entries sent to the parent before the fork, which the parent writes.
      #
      # Also called from a signal trap, such as one that reopens the log files after a rotation, where
      # Ruby does not allow a Mutex to be locked. So within the same process, a receiving thread that
      # runs, or none that was started, is left as it is without taking the lock. When there is more
      # to do, and Ruby refuses the lock, a new thread, which can take it, does it instead, once this
      # call has returned.
      def reopen
        return if @pid == ::Process.pid && (!@started || @thread&.alive?)

        locked = TrapSafe.try_synchronize(@mutex) do
          unless @pid == ::Process.pid
            @port       = ::Ractor::Port.new
            @pid        = ::Process.pid
            @thread     = nil
            @waits      = Queue.new
            @registered = {}
          end
        end
        if locked
          start if @started
        else
          Thread.new { reopen }
          nil
        end
      end

      # Runs the block, which forks the process, while the receiving thread waits on a Queue rather
      # than on the port. Returns the result of the block.
      #
      # The receiving thread first finishes handing over the entries sent before, waiting at most
      # PAUSE_TIMEOUT seconds, after which the fork goes ahead anyway.
      #
      # A pause in a signal trap that interrupted another one on the same thread shares it, rather than
      # asking the receiving thread to pause again: it would only get to the request once the other
      # pause is over, which cannot be before the trap is.
      #
      # Takes no lock, so that it can be called in a signal trap, such as one that forks.
      def pause(&)
        thread = @thread unless RactorSupport.other_ractor?
        return yield unless thread&.alive? && !Thread.current.equal?(thread)

        paused = Thread.current.thread_variable_get(PAUSING)
        if paused
          wait_until_paused(paused)
          # Unless the other pause ended meanwhile, which another Fiber of this thread can do.
          return yield if Thread.current.thread_variable_get(PAUSING).equal?(paused)
        end

        hold_receiving_thread(&)
      end

      # Waits until every entry sent to the port before this call has been handed to the processor,
      # then flushes the processor. Returns the result of the processor's flush.
      #
      # It flushes the processor without waiting on a thread that pauses the receiving thread (see
      # .pause), such as one that flushes while it forks: the receiving thread has handed over the
      # entries sent before the fork began, and waits until it is over. And on a thread inside the
      # processor, such as in a signal trap that interrupted a log call in synchronous mode: the
      # receiving thread would wait for that call to return before it could hand over another entry.
      #
      # Takes no lock, so that it can be called in a signal trap.
      def flush
        thread = @thread
        return Logger.processor.flush unless waits_for_receiving_thread?(thread)

        done = Queue.new
        @port << [:flush, register(done)]
        loop do
          reply = done.pop(timeout: 1)
          return reply.first if reply
          return Logger.processor.flush unless thread.alive?
        end
      end

      private

      # Whether a flush on this thread waits for the receiving thread (see .flush).
      def waits_for_receiving_thread?(thread)
        thread&.alive? && !Thread.current.equal?(thread) && !pausing? && !Logger.processor.current_thread_inside?
      end

      # Whether this thread pauses the receiving thread (see .pause).
      def pausing?
        !Thread.current.thread_variable_get(PAUSING).nil?
      end

      # Runs the block while the receiving thread waits on a Queue (see .pause).
      #
      # The thread variable is set only once the request is sent, so that a pause in a signal trap
      # that interrupted this one before then asks for its own; and cleared before the receiving
      # thread resumes, so that one in a trap after then does too. Both wait for the receiving thread
      # to get to their request, at most PAUSE_TIMEOUT seconds, rather than fork while it waits on the
      # port.
      def hold_receiving_thread
        paused = Queue.new
        resume = Queue.new
        begin
          @port << [:pause, register([paused, resume])]
          Thread.current.thread_variable_set(PAUSING, paused)
          wait_until_paused(paused)
          yield
        ensure
          # Only if it is this pause's, which a pause in another Fiber of this thread may have replaced.
          Thread.current.thread_variable_set(PAUSING, nil) if Thread.current.thread_variable_get(PAUSING).equal?(paused)
          resume.push(true)
        end
      end

      # Waits until the receiving thread closes the Queue, once it waits for the fork to be over, at
      # most PAUSE_TIMEOUT seconds, checking every PAUSE_CHECK_SECONDS.
      def wait_until_paused(paused)
        deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + PAUSE_TIMEOUT
        until paused.closed?
          remaining = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          break unless remaining.positive?

          paused.pop(timeout: [remaining, PAUSE_CHECK_SECONDS].min)
        end
      end

      # Returns [Integer] the token under which the receiving thread finds the supplied Queue(s). Takes
      # no lock: the receiving thread takes them off @waits when it gets to the token.
      def register(waiting)
        token = waiting.object_id
        @waits.push([token, waiting])
        token
      end

      # Returns the Queue(s) registered under the token, or nil. Called only by the receiving thread.
      # Those registered ahead of the token, whose token it has not got to yet, wait in @registered.
      def registered(token)
        waiting = @registered.delete(token)
        return waiting if waiting

        while (entry = @waits.pop(timeout: 0))
          return entry.last if entry.first == token

          @registered.store(*entry)
        end
      end

      # Hands the processor an entry from another Ractor, whose source captures already ran there (see
      # RactorProcessor#log), so that the processor does not run them again on this thread. A stand-in
      # for the processor, such as SemanticLogger::Test::CaptureLogEvents, is handed it with #log.
      def log_captured(log)
        processor = Logger.processor
        processor.respond_to?(:log_captured) ? processor.log_captured(log) : processor.log(log)
      end

      # Receives from the port until it is closed.
      def receive(port)
        loop do
          kind, *args = port.receive
          case kind
          when :log
            log_captured(RactorCopy.unpack(*args))
          when :flush
            flush_and_reply(args.first)
          when :pause
            wait_for_fork(args.first)
          end
        rescue ::Ractor::ClosedError
          break
        rescue StandardError => e
          report("Ractor: Failed to log an entry from another Ractor", e)
        end
      end

      # Flushes the processor, then replies with the result of its flush, or with false when it failed
      # or the thread was stopped meanwhile, so that whoever asked never waits forever.
      def flush_and_reply(requester)
        result = false
        begin
          result = Logger.processor.flush
        rescue StandardError => e
          report("Ractor: Failed to flush the appenders for another Ractor", e)
        end
      ensure
        reply(requester, result)
      end

      # Replies to the thread of the main Ractor that registered the token, or to the Ractor that sent
      # its reply port.
      def reply(requester, result)
        if requester.is_a?(Integer)
          registered(requester)&.push([result])
        else
          requester << result
        end
      rescue ::Ractor::ClosedError
        # The Ractor that asked has stopped waiting.
      end

      # Acknowledges a pause request (see .pause), then waits until the fork is over. It acknowledges by
      # closing the Queue, rather than pushing onto it, so that every wait on it ends, including that of
      # a pause in a signal trap that shares this one, whether or not the pause that the trap
      # interrupted has had the acknowledgement yet.
      def wait_for_fork(token)
        paused, resume = registered(token)
        return unless paused

        paused.close
        resume.pop
      end

      def report(message, exception)
        Logger.processor.logger.error(message, exception)
      rescue StandardError
        nil
      end
    end
  end
end
