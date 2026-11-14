module SemanticLogger
  # Internal, experimental: in the main Ractor, receives the log entries logged in other Ractors and
  # hands them to the processor, which writes them to the appenders. Ruby 4.0 and later only.
  #
  # It knows the port that the other Ractors send to (see RactorProcessor), and runs the thread in
  # the main Ractor that receives from it. The thread starts with the processor's thread, when an
  # appender is added. Entries sent before then wait on the port.
  module RactorReceiver
    @port    = ::Ractor::Port.new
    @pid     = ::Process.pid
    @thread  = nil
    @running = false
    # Pause requests waiting for the receiving thread (see .pause), by token.
    @pauses  = {}
    @tokens  = 0
    @mutex   = Mutex.new

    class << self
      # Returns [Ractor::Port] where other Ractors send their log entries and requests. Any Ractor
      # can read it, since a port is shareable.
      attr_reader :port

      # Returns [true|false] whether the receiving thread has been started. Any Ractor can read it.
      def running?
        @running
      end

      # Starts the receiving thread, unless it is running.
      def start
        return false if @thread&.alive?

        port     = @port
        @running = true
        @thread  = Thread.new do
          Thread.current.name = "SL Ractors"
          receive(port)
        end
        true
      end

      # Restarts the receiving thread in the child process after a fork, if it was running: the thread
      # does not survive the fork. The child also gets a new port, since the port it inherited still
      # holds the entries sent to the parent before the fork, which the parent writes.
      def reopen
        unless @pid == ::Process.pid
          @port   = ::Ractor::Port.new
          @pid    = ::Process.pid
          @thread = nil
        end
        start if @running
      end

      # Runs the block, which forks the process, while the receiving thread waits on a Queue rather
      # than on the port. Returns the result of the block.
      #
      # Ruby 4.0 can crash a forked child process that sends to a port, when a thread of the parent
      # was waiting on a port at the time of the fork. The thread finishes the entry it is handing to
      # the processor first, waiting at most PAUSE_TIMEOUT seconds, after which the fork goes ahead.
      def pause
        return yield unless @thread&.alive? && !Thread.current.equal?(@thread)

        paused = Queue.new
        resume = Queue.new
        token  = @mutex.synchronize { (@tokens += 1).tap { |next_token| @pauses[next_token] = [paused, resume] } }
        @port << [:pause, token]
        paused.pop(timeout: PAUSE_TIMEOUT)
        yield
      ensure
        resume&.push(true)
      end

      PAUSE_TIMEOUT = 5

      # Waits until every entry sent to the port before this call has been handed to the processor,
      # then flushes the processor. Returns the result of the processor's flush.
      def flush
        return Logger.processor.flush unless @thread&.alive? && !Thread.current.equal?(@thread)

        reply = ::Ractor::Port.new
        @port << [:flush, reply]
        reply.receive
      ensure
        reply&.close
      end

      private

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
          report(e)
        end
      end

      # Flushes the processor, then replies to the Ractor that asked: true once flushed, or false when
      # the flush failed, so that it never waits forever.
      def flush_and_reply(reply)
        result = false
        Logger.processor.flush
        result = true
      ensure
        begin
          reply << result
        rescue ::Ractor::ClosedError
          # The Ractor that asked has stopped waiting.
        end
      end

      # Acknowledges a pause request (see .pause), then waits until the fork is over.
      def wait_for_fork(token)
        paused, resume = @mutex.synchronize { @pauses.delete(token) }
        return unless paused

        paused.push(true)
        resume.pop
      end

      def report(exception)
        Logger.processor.logger.error("Ractor: Failed to log an entry from another Ractor", exception)
      rescue StandardError
        nil
      end
    end
  end
end
