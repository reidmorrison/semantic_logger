require_relative "test_helper"
require_relative "signal_trap_helper"

module SemanticLogger
  class SyncProcessorTest < Minitest::Test
    # Records the messages it writes, whether it wrote one while it wrote another, and the threads that
    # flushed, reopened, and closed it. Holds the thread that writes an entry whose message is "hold"
    # until released through #gate, and runs #on_write as it writes each entry.
    class RecordingAppender < SemanticLogger::Subscriber
      attr_reader :messages, :entered, :gate, :flushed_on, :reopened_on, :closed_on
      attr_accessor :on_write

      def initialize
        super
        @messages = []
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
        @messages << log.message
      ensure
        @writing = false
      end

      def overlapped? = @overlapped || false

      def flush = @flushed_on = Thread.current

      def reopen = @reopened_on = Thread.current

      def close
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

        it "writes an entry at once when no other call is inside the processor" do
          written = in_signal_trap do
            sync.log(entry("in trap"))
            recorder.messages.dup
          end

          assert_equal ["in trap"], written
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
          sync.log(entry("interrupted"))

          assert_nil flushed
          assert_equal Thread.current, recorder.flushed_on
        end

        it "reopens the appenders outside the trap" do
          reopened = in_signal_trap do
            sync.reopen
            recorder.reopened_on
          end

          refute_nil reopened
          refute_equal Thread.current, reopened
        end

        it "removes an appender and returns the result of closing it" do
          closed = in_signal_trap { sync.remove(recorder) }

          assert_equal :closed, closed
          refute_includes sync.appenders, recorder
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
          assert_equal 1, stats[:processed]
          assert_equal 0, sync.stats[:queue_size]
          assert_equal 2, sync.stats[:processed]
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
