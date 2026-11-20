require_relative "test_helper"
require_relative "signal_trap_helper"

module SemanticLogger
  class SyncProcessorTest < Minitest::Test
    # Records the messages it writes, the thread that wrote each, whether it wrote one while it wrote
    # another, and the threads that flushed, reopened, and closed it. Holds the thread that writes an
    # entry whose message is "hold" until released through #gate, and runs #on_write as it writes each
    # entry, and #on_close as it closes.
    class RecordingAppender < SemanticLogger::Subscriber
      attr_reader :messages, :writers, :entered, :gate, :flushed_on, :reopened_on, :closed_on
      attr_accessor :on_write, :on_close

      def initialize
        super
        @messages = []
        @writers  = []
        @entered  = Queue.new
        @gate     = Queue.new
        @writing  = false
      end

      def log(log)
        @overlapped = true if @writing
        @writing    = true
        if log.message == "hold"
          @entered << true
          @gate.pop
        end
        on_write&.call(log)
        @writers << Thread.current
        @messages << log.message
      ensure
        @writing = false
      end

      def overlapped? = @overlapped || false

      def flush = @flushed_on = Thread.current

      def reopen = @reopened_on = Thread.current

      def close
        on_close&.call
        @closed_on = Thread.current
        :closed
      end
    end

    describe SemanticLogger::SyncProcessor do
      let(:appender) { SemanticLogger::Test::CaptureLogEvents.new }
      let(:processor) do
        SemanticLogger::SyncProcessor.new(SemanticLogger::Appenders.new.tap { |a| a << appender })
      end

      describe ".logger" do
        it "defaults to a warn level IO appender named after the class" do
          assert_kind_of SemanticLogger::Appender::IO, SemanticLogger::SyncProcessor.logger
          assert_equal :warn, SemanticLogger::SyncProcessor.logger.level
          assert_equal "SemanticLogger::SyncProcessor", SemanticLogger::SyncProcessor.logger.name
        end
      end

      describe ".logger=" do
        it "allows the internal logger to be overridden" do
          original = SemanticLogger::SyncProcessor.logger
          begin
            replacement = SemanticLogger::Appender::IO.new($stdout)
            SemanticLogger::SyncProcessor.logger = replacement

            assert_same replacement, SemanticLogger::SyncProcessor.logger
          ensure
            SemanticLogger::SyncProcessor.logger = original
          end
        end

        it "reports to a Ruby Logger, with the exception" do
          original = SemanticLogger::SyncProcessor.logger
          output   = StringIO.new
          begin
            SemanticLogger::SyncProcessor.logger = ::Logger.new(output)
            processor = SemanticLogger::SyncProcessor.new
            processor.appenders << Class.new(SemanticLogger::Subscriber) do
              def self.name = "FailingAppender"

              def log(_log)
                raise IOError, "destination unavailable"
              end
            end.new
            processor.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "hello" })
            processor.flush

            assert_includes output.string,
                            "SemanticLogger::Appenders -- Failed to log to appender: FailingAppender " \
                            "-- Exception: IOError: destination unavailable"
            refute_includes output.string, "Flushing appender"
          ensure
            SemanticLogger::SyncProcessor.logger = original
          end
        end
      end

      describe "#initialize" do
        it "creates its own Appenders collection when none is supplied" do
          assert_kind_of SemanticLogger::Appenders, SemanticLogger::SyncProcessor.new.appenders
        end

        it "uses the supplied appenders" do
          assert_includes processor.appenders, appender
        end
      end

      describe "#logger" do
        it "returns the internal logger of its appenders" do
          internal  = SemanticLogger::Test::CaptureLogEvents.new
          appenders = SemanticLogger::Appenders.new(internal)

          assert_same internal, SemanticLogger::SyncProcessor.new(appenders).logger
        end
      end

      describe "#add" do
        it "adds an appender" do
          added = processor.add(io: $stdout)

          assert_includes processor.appenders, added
        end
      end

      describe "#log" do
        it "logs synchronously on the calling thread" do
          log         = SemanticLogger::Log.new("Test", :info)
          log.message = "hello"
          processor.log(log)

          assert_includes appender.events, log
        end

        it "reports a stack overflow instead of raising it from the log call" do
          internal    = SemanticLogger::Test::CaptureLogEvents.new
          appenders   = SemanticLogger::Appenders.new(internal)
          overflowing = SemanticLogger::Test::CaptureLogEvents.new
          overflowing.define_singleton_method(:log) { |_log| raise SystemStackError, "stack level too deep" }
          appenders << overflowing
          log         = SemanticLogger::Log.new("Test", :info)
          log.message = "hello"

          SemanticLogger::SyncProcessor.new(appenders).log(log)

          assert_kind_of SystemStackError, internal.events.last.exception
        end
      end

      describe "#log_aside" do
        let(:aside) { SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "aside" } }

        it "logs at once on the thread inside it, such as an appender as it is flushed" do
          sync   = processor
          logged = [aside]
          appender.define_singleton_method(:flush) { sync.log_aside(logged) }
          sync.flush

          assert_includes appender.events, aside
        end

        it "does not wait on another thread for the thread inside it, which writes the entries as it flushes" do
          sync    = processor
          logged  = [aside]
          handed  = nil
          flushed = []
          appender.define_singleton_method(:flush) do
            flushed << events.dup
            # Waits for another thread, as for the worker thread of an appender added with async: true.
            handed ||= Thread.new { sync.log_aside(logged) }.join(5)&.value
          end
          sync.flush

          assert handed, "log_aside on another thread waited for the thread inside the processor"
          assert_equal [[], [aside]], flushed, "the flush should write the entries, then flush them"
        end

        it "has a flush flush again once entries were logged aside as it flushed, at most FLUSHES times" do
          sync    = processor
          flushes = 0
          appender.define_singleton_method(:flush) do
            flushes += 1
            sync.log_aside([SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "again" }])
          end
          sync.flush

          assert_equal SemanticLogger::QueueProcessor::Aside::FLUSHES + 1, flushes
          assert_equal SemanticLogger::QueueProcessor::Aside::FLUSHES + 1, appender.events.size
        end

        it "has a flush flush again once entries were logged aside on another thread as it flushed" do
          sync    = processor
          logged  = [aside]
          flushes = 0
          appender.define_singleton_method(:flush) do
            flushes += 1
            Thread.new { sync.log_aside(logged) }.join(5) if flushes == 1
          end
          sync.flush

          assert_equal 2, flushes
          assert_includes appender.events, aside
        end

        it "flushes once when an appender logs as it is flushed, other than aside" do
          sync    = processor
          flushes = 0
          appender.define_singleton_method(:flush) do
            flushes += 1
            sync.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "logged" })
          end
          sync.flush

          assert_equal 1, flushes
          assert_equal 1, appender.events.size
        end
      end

      describe "#flush, #close, #reopen" do
        it "delegate to the appenders" do
          mock = Minitest::Mock.new
          mock.expect(:flush, nil)
          mock.expect(:close, nil)
          mock.expect(:reopen, nil)

          sync = SemanticLogger::SyncProcessor.new(mock)
          sync.flush
          sync.close
          sync.reopen

          mock.verify
        end
      end

      describe "#current_thread_inside?" do
        it "is true only on the thread inside a call to it" do
          sync   = processor
          inside = []
          appender.define_singleton_method(:log) do |_log|
            inside << sync.current_thread_inside?
            inside << Thread.new { sync.current_thread_inside? }.value
          end
          sync.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "hello" })

          assert_equal [true, false], inside
          refute_predicate sync, :current_thread_inside?
        end
      end

      describe "in a signal trap" do
        include SignalTrapHelper

        let(:recorder) { RecordingAppender.new }
        let(:sync) { SemanticLogger::SyncProcessor.new(SemanticLogger::Appenders.new.tap { |a| a << recorder }) }

        def entry(message) = SemanticLogger::Log.new("Test", :info).tap { |log| log.message = message }

        # Another thread holds the processor, writing an entry until #release.
        def hold
          holder = Thread.new { sync.log(entry("hold")) }
          recorder.entered.pop
          holder
        end

        def release(after: 0)
          Thread.new do
            sleep(after)
            recorder.gate << true
          end
        end

        def wait_for(deadline: Time.now + 5)
          sleep(0.01) until yield || Time.now > deadline
        end

        it "writes an entry on another thread, without the trap waiting for it" do
          writing           = Queue.new
          recorder.on_write = ->(_log) { writing.pop(timeout: 5) }
          written           = in_signal_trap do
            sync.log(entry("in trap"))
            recorder.messages.dup
          end

          assert_empty written
          writing << true
          wait_for { recorder.messages.any? }

          assert_equal ["in trap"], recorder.messages
          refute_equal Thread.current, recorder.writers.first
        end

        it "writes an entry to a Ruby Logger, whose write locks a Mutex" do
          output = StringIO.new
          sync.add(logger: ::Logger.new(output))
          _, stderr = capture_io do
            in_signal_trap { sync.log(entry("in trap")) }
            wait_for { output.string.include?("in trap") }
          end

          assert_includes output.string, "in trap"
          refute_includes stderr, "log writing failed"
        end

        it "writes the entries in the order they were logged, before the next one" do
          in_signal_trap do
            sync.log(entry("first"))
            sync.log(entry("second"))
          end
          sync.log(entry("after"))

          assert_equal %w[first second after], recorder.messages
        end

        it "writes an entry just after the entry that another thread is writing, before the next one" do
          holder  = hold
          written = in_signal_trap do
            sync.log(entry("in trap"))
            recorder.messages.dup
          end

          assert_empty written
          release(after: 0.05)
          sync.log(entry("after"))
          holder.join

          assert_equal ["hold", "in trap", "after"], recorder.messages
        end

        it "writes an entry just after the write that the trap interrupted, not inside it" do
          written           = nil
          recorder.on_write = lambda do |log|
            next unless log.message == "interrupted"

            written = in_signal_trap do
              sync.log(entry("in trap"))
              recorder.messages.dup
            end
          end
          sync.log(entry("interrupted"))
          sync.log(entry("after"))

          assert_empty written
          assert_equal ["interrupted", "in trap", "after"], recorder.messages
          refute_predicate recorder, :overlapped?
        end

        it "writes an entry from a thread of its own when no other call follows" do
          holder = hold
          in_signal_trap { sync.log(entry("in trap")) }
          holder.kill.join
          wait_for { recorder.messages.any? }

          assert_equal ["in trap"], recorder.messages
        end

        it "writes every entry logged in traps that follow one another, with no other call" do
          100.times { |i| in_signal_trap { sync.log(entry(i.to_s)) } }
          wait_for { recorder.messages.size == 100 }

          assert_equal (0...100).map(&:to_s), recorder.messages
        end

        it "flushes the appenders outside the trap, after the entries pending, and waits for it" do
          holder = hold
          release(after: 0.05)
          flushed = in_signal_trap do
            sync.log(entry("in trap"))
            sync.flush
            [recorder.flushed_on, recorder.messages.dup]
          end
          holder.join

          refute_nil flushed.first
          refute_equal Thread.current, flushed.first
          assert_equal ["hold", "in trap"], flushed.last
        end

        it "flushes just after the write that the trap interrupted, without waiting for it" do
          flushed           = :not_called
          recorder.on_write = lambda do |log|
            next unless log.message == "interrupted"

            flushed = in_signal_trap do
              sync.flush
              recorder.flushed_on
            end
          end
          started = Time.now
          sync.log(entry("interrupted"))

          assert_operator Time.now - started, :<, SemanticLogger::SyncProcessor::TRAP_WAIT_SECONDS
          assert_nil flushed
          wait_for { recorder.flushed_on }

          refute_nil recorder.flushed_on
          refute_equal Thread.current, recorder.flushed_on
        end

        it "stops waiting for a flush that cannot run before the trap returns" do
          lock              = Mutex.new
          recorder.on_write = lambda do |log|
            next unless log.message == "locking"

            recorder.entered << true
            lock.synchronize { nil }
          end
          lock.lock
          holder = Thread.new { sync.log(entry("locking")) }
          recorder.entered.pop
          started = Time.now
          flushed = in_signal_trap { sync.flush }
          waited  = Time.now - started
          lock.unlock
          holder.join(5)
          wait_for { recorder.flushed_on }

          assert_nil flushed
          assert_operator waited, :<, SemanticLogger::SyncProcessor::TRAP_WAIT_SECONDS + 2
          refute_nil recorder.flushed_on
        end

        it "reopens the appenders outside the trap" do
          reopened = in_signal_trap do
            sync.reopen
            recorder.reopened_on
          end

          refute_nil reopened
          refute_equal Thread.current, reopened
        end

        it "adds an appender outside the trap and returns it" do
          other = RecordingAppender.new
          added = in_signal_trap { sync.add(appender: other) }

          assert_same other, added
          assert_includes sync.appenders, other
        end

        it "removes an appender and returns the result of closing it, outside the trap" do
          closed = in_signal_trap { sync.remove(recorder) }

          assert_equal :closed, closed
          refute_includes sync.appenders, recorder
          refute_equal Thread.current, recorder.closed_on
        end

        it "closes the appenders" do
          in_signal_trap { sync.close }

          refute_nil recorder.closed_on
          assert_empty sync.appenders
        end

        it "raises what a call raised outside the trap" do
          recorder.define_singleton_method(:close) { raise IOError, "cannot close" }
          raised = in_signal_trap { sync.remove(recorder) }

          assert_kind_of IOError, raised
        end

        it "returns the statistics, counting the entries still to be written" do
          holder = hold
          stats  = in_signal_trap do
            sync.log(entry("in trap"))
            sync.stats
          end
          release
          holder.join

          assert_equal 1, stats[:queue_size]
          assert stats[:thread_active]
          assert_equal 1, stats[:processed]
          assert_equal 0, sync.stats[:queue_size]
          assert_equal 0, sync.queue_size
          assert_equal 2, sync.stats[:processed]
        end

        it "leaves the entries pending in the parent to the parent, after a fork" do
          skip "fork is not available" unless Process.respond_to?(:fork)

          sync.stub(:start_runner, nil) { in_signal_trap { sync.log(entry("parent")) } }
          reader, writer = IO.pipe
          pid            = fork do
            reader.close
            sync.log(entry("child"))
            writer.write(recorder.messages.join(","))
            writer.close
            exit!(0)
          end
          writer.close
          child = reader.read
          reader.close
          Process.wait(pid)
          sync.log(entry("after"))

          assert_equal "child", child
          assert_equal %w[parent after], recorder.messages
        end

        it "does not count the entries pending in the parent, in a forked child" do
          skip "fork is not available" unless Process.respond_to?(:fork)

          sync.stub(:start_runner, nil) { in_signal_trap { sync.log(entry("parent")) } }
          reader, writer = IO.pipe
          pid            = fork do
            reader.close
            writer.write([sync.queue_size, sync.stats[:queue_size]].join(","))
            writer.close
            exit!(0)
          end
          writer.close
          child = reader.read
          reader.close
          Process.wait(pid)

          assert_equal "0,0", child
          assert_equal 1, sync.queue_size
          sync.flush

          assert_equal ["parent"], recorder.messages
        end

        # Such as an Interrupt, Timeout, or Thread#raise interrupting the call, outside the appenders.
        it "leaves the monitor when a call left by a trap raises past its rescue" do
          recorder.on_write = lambda do |log|
            in_signal_trap { sync.log(entry("in trap")) } if log.message == "interrupted"
          end
          write = sync.method(:write)
          raise_in_trap_call = ->(log) { log.message == "in trap" ? raise(Interrupt) : write.call(log) }

          sync.stub(:write, raise_in_trap_call) do
            assert_raises(Interrupt) { sync.log(entry("interrupted")) }
          end
          other = Thread.new { sync.log(entry("other thread")) }

          refute_nil other.join(5), "another thread should enter the monitor"
          assert_equal ["interrupted", "other thread"], recorder.messages
        ensure
          other&.kill
        end
      end

      describe "outside a signal trap" do
        let(:recorder) { RecordingAppender.new }
        let(:sync) { SemanticLogger::SyncProcessor.new(SemanticLogger::Appenders.new.tap { |a| a << recorder }) }

        def entry(message) = SemanticLogger::Log.new("Test", :info).tap { |log| log.message = message }

        it "closes a removed appender while other threads log" do
          sync.add(appender: SemanticLogger::Test::CaptureLogEvents.new)
          logged            = nil
          recorder.on_close = lambda do
            logger = Thread.new { sync.log(entry("while closing")) }
            logged = !logger.join(2).nil?
            logger.kill
          end
          sync.remove(recorder)

          assert logged, "another thread should log while the appender closes"
        end

        it "does not check for a signal trap to log, flush, or reopen" do
          SemanticLogger::TrapSafe.stub(:in_trap?, -> { flunk "checked for a trap" }) do
            sync.log(entry("free"))
            holder = Thread.new { sync.log(entry("hold")) }
            recorder.entered.pop
            Thread.new do
              sleep(0.05)
              recorder.gate << true
            end
            sync.log(entry("contended"))
            holder.join
            sync.flush
            sync.reopen
          end

          assert_equal %w[free hold contended], recorder.messages
        end

        it "raises ThreadError for a fiber when another fiber of its thread is inside, as before" do
          recorder.on_write = ->(log) { Fiber.yield if log.message == "paused" }
          paused            = Fiber.new { sync.log(entry("paused")) }
          paused.resume

          assert_raises(ThreadError) { sync.log(entry("other fiber")) }
          paused.resume
          sync.log(entry("after"))

          assert_equal %w[paused after], recorder.messages
        ensure
          paused.resume if paused&.alive?
        end

        it "reports a stack overflow raised while closing instead of raising it" do
          internal  = SemanticLogger::Test::CaptureLogEvents.new
          appenders = SemanticLogger::Appenders.new(internal)
          sync      = SemanticLogger::SyncProcessor.new(appenders)

          closed = appenders.stub(:close, -> { raise SystemStackError, "stack level too deep" }) { sync.close }

          assert_nil closed
          assert_kind_of SystemStackError, internal.events.last.exception
        end

        it "reports a stack overflow raised outside the appenders instead of raising it" do
          internal = SemanticLogger::Test::CaptureLogEvents.new
          sync     = SemanticLogger::SyncProcessor.new(SemanticLogger::Appenders.new(internal))
          monitor  = sync.instance_variable_get(:@monitor)

          logged = monitor.stub(:enter, -> { raise SystemStackError, "stack level too deep" }) do
            sync.log(entry("deep"))
          end

          refute logged
          assert_kind_of SystemStackError, internal.events.last.exception
        end
      end

      describe "#start" do
        it "is a no-op" do
          assert_nil processor.start
        end
      end
    end
  end
end
