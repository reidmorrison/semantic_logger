require_relative "test_helper"
require_relative "signal_trap_helper"
require_relative "forked_child_helper"

module SemanticLogger
  class ProcessorTest < Minitest::Test
    describe SemanticLogger::Processor do
      # Track every processor created so its worker thread can be stopped after each test.
      let(:created) do
        []
      end

      let(:processor) do
        SemanticLogger::Processor.new.tap { |p| created << p }
      end

      after do
        created.each do |p|
          thread = p.processor.instance_variable_get(:@thread)
          next unless thread

          thread.kill
          thread.join
        end
      end

      describe ".logger" do
        it "defaults to an IO appender writing to stderr at warn level" do
          assert_kind_of SemanticLogger::Appender::IO, SemanticLogger::Processor.logger
          assert_equal :warn, SemanticLogger::Processor.logger.level
        end

        it "names the internal logger after the Processor" do
          assert_equal "SemanticLogger::Processor", SemanticLogger::Processor.logger.name
        end
      end

      describe ".logger=" do
        it "allows the internal logger to be overridden" do
          original = SemanticLogger::Processor.logger
          begin
            replacement = SemanticLogger::Appender::IO.new($stdout)
            SemanticLogger::Processor.logger = replacement

            assert_equal replacement, SemanticLogger::Processor.logger
          ensure
            SemanticLogger::Processor.logger = original
          end
        end

        it "restores the default for nil" do
          original = SemanticLogger::Processor.logger
          begin
            SemanticLogger::Processor.logger = nil

            assert_kind_of SemanticLogger::Appender::IO, SemanticLogger::Processor.logger
          ensure
            SemanticLogger::Processor.logger = original
          end
        end

        it "restores the default for false" do
          original = SemanticLogger::Processor.logger
          begin
            SemanticLogger::Processor.logger = false

            assert_kind_of SemanticLogger::Appender::IO, SemanticLogger::Processor.logger
          ensure
            SemanticLogger::Processor.logger = original
          end
        end

        it "refuses a SemanticLogger::Logger, keeping the internal logger" do
          original = SemanticLogger::Processor.logger

          assert_raises(ArgumentError) { SemanticLogger::Processor.logger = SemanticLogger["Internal"] }
          assert_same original, SemanticLogger::Processor.logger
        end

        describe "with a Ruby Logger" do
          let(:output) { StringIO.new }
          let(:ruby_logger) { ::Logger.new(output) }

          before do
            @original                        = SemanticLogger::Processor.logger
            SemanticLogger::Processor.logger = ruby_logger
          end

          after { SemanticLogger::Processor.logger = @original }

          it "wraps it in an appender that writes to it" do
            assert_kind_of SemanticLogger::Appender::Wrapper, SemanticLogger::Processor.logger
            assert_same ruby_logger, SemanticLogger::Processor.logger.wrapped_logger
          end

          it "reports an appender that fails to it, with the exception" do
            failing = Class.new(SemanticLogger::Subscriber) do
              def self.name = "FailingAppender"

              def log(_log)
                raise IOError, "destination unavailable"
              end
            end
            processor.appenders << failing.new
            processor.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "hello" })

            assert processor.flush, "the worker thread should flush"
            assert_includes output.string, "ERROR -- : "
            assert_includes output.string,
                            "SemanticLogger::Appenders -- Failed to log to appender: FailingAppender " \
                            "-- Exception: IOError: destination unavailable"
          end

          it "is the internal logger of the processor" do
            processor.logger.warn("Something went wrong", RuntimeError.new("boom"))

            assert_includes output.string, "WARN -- : "
            assert_includes output.string, "Something went wrong -- Exception: RuntimeError: boom"
          end

          it "flushes the appenders, without writing the trace reports" do
            processor.appenders.add(io: StringIO.new)

            assert processor.flush, "the worker thread should flush"
            refute_includes output.string, "Flushing appender"
          end

          it "is the internal logger of the appenders added from then on, named after each one" do
            appender = processor.appenders.add(io: StringIO.new)
            appender.logger.warn("Could not write")

            assert_includes output.string, "SemanticLogger::Appender::IO -- Could not write"
          end
        end
      end

      describe "#initialize" do
        it "is an async appender" do
          assert_kind_of SemanticLogger::Appender::Async, processor
        end

        it "owns an Appenders collection" do
          assert_kind_of SemanticLogger::Appenders, processor.appenders
        end

        it "honours the supplied max_queue_size" do
          processor = SemanticLogger::Processor.new(max_queue_size: 42).tap { |p| created << p }

          assert_equal 42, processor.max_queue_size
        end

        it "starts the worker thread" do
          assert_predicate processor, :active?
        end
      end

      describe "#stats" do
        it "reports pipeline statistics including per-appender stats" do
          stats = processor.stats

          assert_kind_of Integer, stats[:queue_size]
          assert_kind_of Integer, stats[:processed]
          assert_equal 0, stats[:dropped]
          assert_predicate processor, :active?
          assert stats[:thread_active]
          assert_kind_of Array, stats[:appenders]
        end

        it "includes an entry per appender" do
          processor.appenders.add(io: StringIO.new)

          assert_equal processor.appenders.size, processor.stats[:appenders].size
        end
      end

      describe "#non_blocking=" do
        it "defaults to blocking" do
          refute_predicate processor, :non_blocking?
        end

        it "drops messages on the main queue once it is full" do
          processor = SemanticLogger::Processor.new(max_queue_size: 2).tap { |p| created << p }
          processor.non_blocking = true

          # Stop the worker thread so the queue is not drained while we fill it.
          worker = processor.thread
          worker.kill
          worker.join

          log = SemanticLogger::Log.new("Test", :info)
          4.times { processor.log(log) }

          assert_equal 2, processor.queue.size, "queue must not grow beyond its cap"
          assert_equal 2, processor.stats[:dropped]
        ensure
          processor&.queue&.clear
        end
      end

      describe "#reopen" do
        include SignalTrapHelper

        # Records the thread it is reopened on. Its reopen locks a Mutex, as connecting with a timeout
        # does, which Ruby does not allow in a signal trap.
        let(:reopening) do
          Class.new(SemanticLogger::Test::CaptureLogEvents) do
            def reopened_on
              @reopened_on ||= Queue.new
            end

            def reopen
              Mutex.new.synchronize { nil }
              reopened_on << Thread.current
            end
          end.new
        end

        before { processor.appenders << reopening }

        it "reopens the appenders on the thread that writes to them, ahead of the next entry" do
          processor.reopen

          assert processor.flush, "the worker thread should answer the flush"
          assert_equal processor.thread, reopening.reopened_on.pop(timeout: 0)
        end

        it "can be called in a signal trap, from which it does not reopen the appenders" do
          assert processor.flush, "the worker thread should be waiting for the next entry"
          reopened = in_signal_trap do
            processor.reopen
            :reopened
          end

          assert_equal :reopened, reopened
          assert_equal processor.thread, reopening.reopened_on.pop(timeout: 5)
        end

        it "starts the worker thread of an appender added with async: true at once in a child process" do
          skip "fork is not supported" unless Process.respond_to?(:fork)

          gate = Queue.new
          # Holds the worker thread of the processor while it reopens the appenders, ahead of the async one.
          processor.appenders.unshift(
            Class.new(SemanticLogger::Test::CaptureLogEvents) { define_method(:reopen) { gate.pop } }.new
          )
          wrapped = reopening.class.new
          async   = SemanticLogger::Appender::Async.new(appender: wrapped)
          processor.appenders << async
          reader, writer = IO.pipe
          # The child exits whatever happens, so that a failure there does not run the tests again in it.
          pid            = fork do
            reader.close
            processor.reopen
            active = async.active?
            gate << true
            processor.flush
            writer.write([active, wrapped.reopened_on.pop(timeout: 5).equal?(async.thread)].inspect)
            writer.close
          ensure
            exit!(0)
          end
          writer.close
          Process.wait(pid)
          result = reader.read
          reader.close
          async.close

          assert_equal "[true, true]", result
        end
      end

      # At exit, the flush reaches an appender added with async: true only once this processor's
      # worker thread has handed it the entries ahead of the flush.
      describe "with its appenders told that the process is exiting" do
        # Cannot reach its destination, and says that each write wrote nothing, so that its worker
        # thread holds the entry and backs off. Counts its writes.
        let(:down) do
          appender = Class.new(SemanticLogger::Subscriber) do
            def attempts = @attempts ||= Queue.new

            def log(_log)
              attempts << true
              raise IOError, "destination unavailable"
            end

            def wrote_nothing?(_exception) = true
          end.new
          appender.logger = SemanticLogger::Test::CaptureLogEvents.new
          appender
        end

        let(:healthy) { SemanticLogger::Test::CaptureLogEvents.new }

        it "flushes within seconds while its worker thread waits on the full queue of an appender backing off" do
          async = SemanticLogger::Appender::Async.new(appender: down, max_queue_size: 2)
          processor.appenders << async << healthy
          # Counts 30 failures, so that the back-off after the first entry lasts 31 seconds, longer than
          # the test waits: the entry held is written again only once the appenders are told.
          backoff = async.processor.instance_variable_get(:@backoff)
          30.times { backoff.retry? }
          20.times { |i| processor.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "entry #{i}" }) }
          deadline = Time.now + 5
          Thread.pass until (async.processor.retry_count > 30 && async.queue.num_waiting == 1) ||
                            Time.now > deadline

          assert_equal 1, async.queue.num_waiting, "the worker thread should be waiting for room"
          started                             = Time.now
          processor.appenders.process_exiting = true

          assert processor.flush
          assert_operator Time.now - started, :<, 3
          assert_equal 20, async.failed_count
          # The entry held tried once more, then none of the others.
          assert_equal 2, down.attempts.size
          assert_equal 20, healthy.events.size
        ensure
          processor.appenders.process_exiting = false
          async&.close
        end
      end

      # Calls into the processor from the worker thread of an appender added with async: true, as it
      # writes: the worker thread of the processor may be waiting for that thread, so it must not wait.
      describe "on the worker thread of an appender added with async: true" do
        include ForkedChildHelper

        # Runs the block given to #on_write, with the message, on its worker thread as it writes.
        let(:caller_class) do
          Class.new(SemanticLogger::Subscriber) do
            attr_reader :events

            def initialize(...)
              super
              @events = Queue.new
            end

            def on_write(&block)
              @on_write = block
            end

            def log(log)
              @on_write&.call(log.message)
              true
            end

            def close
              events << [:closed, Thread.current]
              true
            end
          end
        end

        # Records what happens to it, and writes "slow" only once released.
        let(:victim_class) do
          Class.new(SemanticLogger::Subscriber) do
            attr_reader :events, :release

            def initialize(...)
              super
              @events  = Queue.new
              @release = Queue.new
            end

            def log(log)
              return true unless log.message == "slow"

              events << :writing
              release.pop(timeout: 5)
              events << :written
            end

            def close
              events << [:closed, Thread.current]
              true
            end
          end
        end

        let(:caller_appender) { caller_class.new }
        let(:async_options) { {} }
        let(:async) { processor.appenders.add(appender: caller_appender, async: true, **async_options) }
        let(:victim) { victim_class.new }
        let(:results) { Queue.new }
        let(:internal_logger) { SemanticLogger::Test::CaptureLogEvents.new }

        before do
          processor.appenders.logger = internal_logger
        end

        after do
          victim.release << true
          async.processor.instance_variable_get(:@thread)&.kill
        end

        def log(message)
          processor.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = message })
        end

        def drain(queue) = Array.new(queue.size) { queue.pop }

        # Waits up to 5 seconds for the block to return true.
        def wait_for
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
          sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        end

        it "removes another appender, and the worker thread of the processor closes it, after it returns" do
          processor.appenders << victim
          caller_appender.on_write { |_message| results << processor.remove(victim) }
          async
          log("remove")

          assert results.pop(timeout: 5), "remove did not return"
          assert processor.flush
          refute_includes processor.appenders, victim

          assert_equal [[:closed, processor.thread]], drain(victim.events)
        end

        it "does not close the appender while the worker thread of the processor writes to it" do
          async
          processor.appenders << victim
          caller_appender.on_write { |message| results << processor.remove(victim) if message == "slow" }
          log("slow")

          assert results.pop(timeout: 5), "remove did not return"
          assert_equal :writing, victim.events.pop(timeout: 5)
          sleep 0.1

          assert_predicate victim.events, :empty?, "it closed the appender while it was being written to"

          victim.release << true

          assert processor.flush
          assert_equal [:written, [:closed, processor.thread]], drain(victim.events)
        end

        it "closes the appender that removes itself, once its write has returned" do
          caller_appender.on_write { |_message| results << [processor.remove(async), Thread.current] }
          async
          log("remove me")

          removed, worker = results.pop(timeout: 5)

          assert removed, "remove did not return"
          assert processor.flush
          refute_includes processor.appenders, async
          assert_equal [[:closed, worker]], drain(caller_appender.events)
          assert worker.join(5), "the worker thread of the appender should end once it is closed"
        end

        it "still returns from #flush and #close at once after the appender removed itself" do
          caller_appender.on_write do |_message|
            removed = processor.remove(async)
            # Gives the worker thread of the processor time to start closing the appender.
            sleep 0.1
            results << [removed, processor.flush, processor.close, processor.current_thread_inside?]
          end
          async
          log("remove me")

          assert_equal [true, false, false, true], results.pop(timeout: 5), "flush or close did not return"

          flushing = Thread.new { processor.flush }

          assert flushing.join(5), "the processor no longer flushes"
          refute_includes processor.appenders, async
          assert_equal 1, drain(caller_appender.events).size
        end

        it "closes the appender it removes when a close of every appender is queued ahead" do
          gate = Queue.new
          caller_appender.on_write do |message|
            next unless message == "trigger"

            gate.pop(timeout: 5)
            results << processor.remove(victim)
          end
          async
          processor.appenders << victim
          log("trigger")
          log("slow")

          assert_equal :writing, victim.events.pop(timeout: 5)
          worker  = processor.thread
          closing = Thread.new { processor.close }
          wait_for { processor.queue.size == 1 }
          gate << true

          assert results.pop(timeout: 5), "remove did not return"
          victim.release << true

          assert closing.join(5), "close did not return"
          assert_equal [:written, [:closed, worker]], drain(victim.events)
          assert_empty processor.appenders
        end

        it "closes every appender when one removes an appender ahead of it while they are being closed" do
          gate  = Queue.new
          after = victim_class.new
          caller_appender.on_write do |_message|
            gate.pop(timeout: 5)
            results << processor.remove(victim)
          end
          processor.appenders << victim
          async
          processor.appenders << after
          log("remove")

          worker  = processor.thread
          closing = Thread.new { processor.close }
          # The worker thread of the processor waits for the appender's worker thread to flush it.
          wait_for { async.queue.size == 1 }
          gate << true

          assert results.pop(timeout: 5), "remove did not return"
          assert closing.join(5), "close did not return"
          assert_equal [[:closed, worker]], drain(victim.events)
          assert_equal [[:closed, worker]], drain(after.events)
          assert_empty processor.appenders
        end

        it "reports an error of any class that closing the appender raises, and carries on" do
          victim.define_singleton_method(:close) { raise NotImplementedError, "no close" }
          processor.appenders << victim
          caller_appender.on_write { |_message| results << processor.remove(victim) }
          async
          log("remove")

          assert results.pop(timeout: 5), "remove did not return"
          assert processor.flush, "the worker thread of the processor stopped"
          refute_includes processor.appenders, victim

          report = internal_logger.events.find { |event| event.message.include?("Failed to close appender") }

          assert_kind_of NotImplementedError, report&.exception
        end

        it "moves the worker thread of the processor to a new thread when closing the appender overflows the stack" do
          victim.define_singleton_method(:close) { raise SystemStackError, "stack level too deep" }
          processor.appenders << victim
          caller_appender.on_write { |_message| results << processor.remove(victim) }
          async
          worker = processor.thread
          log("remove")

          assert results.pop(timeout: 5), "remove did not return"
          assert worker.join(5), "the worker thread of the processor should end once its stack overflowed"
          assert processor.flush, "a new worker thread should carry on"
          refute_includes processor.appenders, victim
          refute_predicate processor.processor, :stopped?
        end

        it "closes the appender once when it is removed on another thread while its removal is pending" do
          closing = Queue.new
          gate    = Queue.new
          victim.define_singleton_method(:close) do
            closing << true
            gate.pop(timeout: 5)
            events << [:closed, Thread.current]
            true
          end
          processor.appenders << victim
          caller_appender.on_write { |_message| results << processor.remove(victim) }
          async
          log("remove")

          assert results.pop(timeout: 5), "remove did not return"
          assert closing.pop(timeout: 5), "the worker thread of the processor did not start closing the appender"
          removing = Thread.new { processor.remove(victim) }
          # Gives the removal time to reach the appender while its handed-over removal is closing it.
          sleep 0.1
          gate << true

          assert removing.join(5), "remove did not return"
          assert removing.value
          assert_equal [[:closed, processor.thread]], drain(victim.events)
          refute_includes processor.appenders, victim
        end

        it "still removes the appender in a forked child when the fork comes before the removal is done" do
          caller_appender.on_write { |message| results << processor.remove(victim) if message == "slow" }
          async
          processor.appenders << victim
          # The worker thread of the processor hands "slow" to the appender, then holds on writing it to
          # the victim, so that the removal that the appender hands over waits on the queue.
          log("slow")

          assert_equal :writing, victim.events.pop(timeout: 5)
          assert results.pop(timeout: 5), "remove did not return"

          child = in_forked_child do
            processor.reopen
            processor.flush
            [processor.appenders.include?(victim), drain(victim.events).last&.first].inspect
          end

          assert_equal "[false, :closed]", child
          victim.release << true

          assert processor.flush
          refute_includes processor.appenders, victim
        end

        it "closes the appender when removed in a forked child that has not reopened the processor" do
          caller_appender.on_write { |message| results << processor.remove(victim) if message == "slow" }
          async
          processor.appenders << victim
          # The worker thread of the processor holds on writing "slow" to the victim, so that the removal
          # that the appender hands over waits on the queue, which the child inherits but never runs.
          log("slow")

          assert_equal :writing, victim.events.pop(timeout: 5)
          assert results.pop(timeout: 5), "remove did not return"

          child = in_forked_child do
            removed = processor.remove(victim)
            [removed, processor.appenders.include?(victim), drain(victim.events).last&.first].inspect
          end

          assert_equal "[true, false, :closed]", child
          victim.release << true

          assert processor.flush
          refute_includes processor.appenders, victim
        end

        describe "when the queue of the processor is full" do
          let(:processor) { SemanticLogger::Processor.new(max_queue_size: 1).tap { |p| created << p } }
          let(:async_options) { {max_queue_size: 1} }

          it "waits for room for a message it logs while the processor waits on another appender" do
            gate  = Queue.new
            asked = Queue.new
            # Records each time the message waiting for room asks whether to keep waiting.
            processor.processor.define_singleton_method(:waited_on?) { super().tap { asked << true } }
            caller_appender.on_write do |message|
              next unless message == "second"

              gate.pop(timeout: 5)
              results << [processor.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "inner" })]
            end
            # Its own queue holds more than the others, so that it is never full here.
            async_options[:max_queue_size] = 100
            async
            blocker = processor.appenders.add(appender: victim, async: true, max_queue_size: 1)
            # The victim's worker thread holds on writing "slow", its queue holds the first, and the
            # worker thread of the processor waits for room on it with the second, while the third
            # fills the queue of the processor.
            log("slow")

            assert_equal :writing, victim.events.pop(timeout: 5)
            log("first")
            wait_for { blocker.queue.size == 1 }
            log("second")
            wait_for { processor.queue.empty? }
            log("third")
            gate << true

            # It has asked whether to keep waiting, and was told to: otherwise it would have dropped the message.
            assert asked.pop(timeout: 5), "the message logged by the appender did not wait for room"
            victim.release << true

            assert_equal [true], results.pop(timeout: 5), "the message logged by the appender was dropped"
            assert processor.flush
            assert_equal 0, processor.dropped_count
            blocker.close
          end

          it "drops a message it logs while the processor waits for it to flush the appender" do
            gate    = Queue.new
            writing = Queue.new
            caller_appender.on_write do |message|
              next unless message == "first"

              writing << true
              gate.pop(timeout: 5)
              results << [processor.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "inner" })]
            end
            # Its own queue holds more than the others, so that it is never full here.
            async_options[:max_queue_size] = 100
            async
            log("first")

            assert writing.pop(timeout: 5), "the appender did not write the first"
            flushing = Thread.new { processor.flush }
            # The worker thread of the processor waits for the appender's worker thread to run the flush,
            # while the second fills the queue of the processor.
            wait_for { async.queue.size == 1 }
            log("second")
            gate << true

            assert_equal [false], results.pop(timeout: 5), "the message logged by the appender waited for room"
            assert flushing.join(5), "the flush did not return"
            assert processor.flush
          end

          it "drops a message it logs, rather than wait for the processor that waits for it" do
            gate = Queue.new
            caller_appender.on_write do |message|
              next unless message == "first"

              gate.pop(timeout: 5)
              results << [processor.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "inner" })]
            end
            async
            # The appender's worker thread writes the first, its queue holds the second, and the worker
            # thread of the processor waits for room on it with the third, while the fourth fills the
            # queue of the processor.
            log("first")
            wait_for { async.queue.empty? }
            log("second")
            wait_for { async.queue.size == 1 }
            log("third")
            wait_for { processor.queue.empty? }
            log("fourth")
            gate << true

            assert_equal [false], results.pop(timeout: 5), "the message logged by the appender waited for room"
            assert processor.flush
          end
        end

        it "returns false from #flush and #close at once, reported once to the internal logger" do
          caller_appender.on_write { |_message| results << [processor.flush, processor.close] }
          async
          log("first")
          log("second")

          assert_equal [false, false], results.pop(timeout: 5), "flush or close did not return"
          assert_equal [false, false], results.pop(timeout: 5), "flush or close did not return"
          assert processor.flush

          reports = internal_logger.events.select { |event| event.message.include?("worker thread of an appender") }

          assert_equal 1, reports.size
          assert_equal :warn, reports.first.level
          assert_includes processor.appenders, async
        end

        it "tells the calling thread not to wait for a thread that uses the processor" do
          caller_appender.on_write { |_message| results << processor.current_thread_inside? }
          async
          log("inside")

          assert results.pop(timeout: 5)
        end
      end

      describe "#close" do
        it "moves its worker thread to a new thread when closing an appender overflows the stack" do
          overflowing = SemanticLogger::Test::CaptureLogEvents.new
          overflowing.define_singleton_method(:close) { raise SystemStackError, "stack level too deep" }
          processor.appenders << overflowing
          worker = processor.thread

          refute processor.close, "the close failed"
          assert worker.join(5), "the worker thread should end once its stack overflowed"
          assert processor.flush, "a new worker thread should carry on"
          assert_includes processor.appenders, overflowing
        end
      end

      describe "#current_thread_inside?" do
        it "is false, even on its worker thread while it writes" do
          async    = processor
          inside   = []
          appender = SemanticLogger::Test::CaptureLogEvents.new
          appender.define_singleton_method(:log) { |_log| inside << async.current_thread_inside? }
          async.appenders << appender
          async.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "hello" })
          async.flush

          assert_equal [false], inside
          refute_predicate async, :current_thread_inside?
        end
      end

      describe "#start" do
        it "returns false when the worker thread is already active" do
          assert_predicate processor, :active?
          refute processor.start
        end

        it "returns true and starts the thread when not active" do
          thread = processor.processor.instance_variable_get(:@thread)
          thread.kill
          thread.join

          refute_predicate processor, :active?

          assert processor.start
          assert_predicate processor, :active?
        end
      end
    end
  end
end
