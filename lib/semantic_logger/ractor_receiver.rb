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
  module RactorReceiver
    # Seconds that .pause waits for the receiving thread to finish the entry it is handing over.
    PAUSE_TIMEOUT = 5

    @port    = ::Ractor::Port.new
    @pid     = ::Process.pid
    @thread  = nil
    # Whether the receiving thread was started, so that .reopen starts it again in a child process.
    @started = false
    # The pid of the process whose receiving thread runs, or nil when none runs.
    @running = nil
    @paused  = 0
    # The Queues that threads of the main Ractor wait on for the receiving thread, by token.
    @waits   = {}
    @tokens  = 0
    @mutex   = Mutex.new

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

        locked = false
        @mutex.synchronize do
          locked = true
          unless @pid == ::Process.pid
            @port   = ::Ractor::Port.new
            @pid    = ::Process.pid
            @thread = nil
            @paused = 0
            @waits  = {}
          end
        end
        start if @started
      rescue ThreadError
        raise if locked

        Thread.new { reopen }
        nil
      end

      # Runs the block, which forks the process, while the receiving thread waits on a Queue rather
      # than on the port. Returns the result of the block.
      #
      # The receiving thread first finishes handing over the entries sent before, waiting at most
      # PAUSE_TIMEOUT seconds, after which the fork goes ahead anyway.
      def pause
        thread = @thread unless RactorSupport.other_ractor?
        return yield unless thread&.alive? && !Thread.current.equal?(thread)

        paused  = Queue.new
        resume  = Queue.new
        counted = false
        # An exception raised into this thread, such as by Timeout, must not leave the count wrong.
        token   = Thread.handle_interrupt(Object => :never) do
          @mutex.synchronize do
            @paused += 1
            counted  = true
            register_locked([paused, resume])
          end
        end
        @port << [:pause, token]
        paused.pop(timeout: PAUSE_TIMEOUT)
        yield
      ensure
        if counted
          Thread.handle_interrupt(Object => :never) { @mutex.synchronize { @paused -= 1 } }
          resume.push(true)
        end
      end

      # Waits until every entry sent to the port before this call has been handed to the processor,
      # then flushes the processor. Returns the result of the processor's flush.
      #
      # While the process forks (see .pause), it flushes the processor without waiting: the receiving
      # thread has handed over the entries sent before the fork began, and waits until it is over.
      def flush
        thread = @thread
        return Logger.processor.flush unless thread&.alive? && !Thread.current.equal?(thread) && @paused.zero?

        done = Queue.new
        @port << [:flush, register(done)]
        loop do
          reply = done.pop(timeout: 1)
          return reply.first if reply
          return Logger.processor.flush unless thread.alive?
        end
      end

      private

      # Returns [Integer] the token under which the receiving thread finds the supplied Queue(s).
      def register(waiting)
        @mutex.synchronize { register_locked(waiting) }
      end

      def register_locked(waiting)
        token         = (@tokens += 1)
        @waits[token] = waiting
        token
      end

      def registered(token)
        @mutex.synchronize { @waits.delete(token) }
      end

      # Receives from the port until it is closed.
      def receive(port)
        loop do
          kind, *args = port.receive
          case kind
          when :log
            Logger.processor.log(RactorCopy.unpack(*args))
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

      # Acknowledges a pause request (see .pause), then waits until the fork is over.
      def wait_for_fork(token)
        paused, resume = registered(token)
        return unless paused

        paused.push(true)
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
