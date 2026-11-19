require_relative "test_helper"
require_relative "signal_trap_helper"

class QueueProcessorTest < Minitest::Test
  # Captures log events in memory and records flush/close calls.
  class SimpleAppender < SemanticLogger::Test::CaptureLogEvents
    attr_reader :flushed, :closed

    def flush
      @flushed = true
    end

    def close
      @closed = true
    end
  end

  # A minimal appender that does not support batching.
  class PlainAppender < SemanticLogger::Subscriber
    def log(log)
    end
  end

  # Adds batch support on top of SimpleAppender.
  class BatchAppender < SimpleAppender
    attr_reader :batches

    def batch(logs)
      (@batches ||= []) << logs
    end
  end

  # Cannot serialize a message containing "poison", as a JSON formatter cannot serialize a value.
  class PoisonedAppender < SimpleAppender
    def log(log)
      raise JSON::GeneratorError, "cannot serialize" if log.message.include?("poison")

      super
    end
  end

  # Batch support on top of PoisonedAppender: the whole batch fails if any message is poisoned.
  class PoisonedBatchAppender < PoisonedAppender
    attr_reader :batches

    def batch(logs)
      raise JSON::GeneratorError, "cannot serialize" if logs.any? { |log| log.message.include?("poison") }

      (@batches ||= []) << logs
    end

    def batch_all_or_nothing?
      true
    end
  end

  # Batch support on top of PoisonedAppender that writes one message at a time, so that a
  # poisoned message fails the batch after the messages before it were written.
  class PoisonedItemBatchAppender < PoisonedAppender
    def batch(logs)
      logs.each { |log| self.log(log) }
    end
  end

  # Batch support on top of SimpleAppender, for a destination that is unavailable.
  class UnavailableBatchAppender < SimpleAppender
    def batch(_logs)
      raise "destination unavailable"
    end
  end

  # Overflows the stack on a message containing "deep", as #inspect does on a value nested too deeply.
  # Records the threads it was called on.
  class StackOverflowAppender < SimpleAppender
    def threads
      @threads ||= []
    end

    def log(log)
      threads << Thread.current
      raise SystemStackError, "stack level too deep" if log.message.include?("deep")

      super
    end

    def batch(logs)
      threads << Thread.current
      raise SystemStackError, "stack level too deep" if logs.any? { |log| log.message.include?("deep") }

      logs.each { |log| events << log }
    end

    def batch_all_or_nothing?
      true
    end
  end

  # Formats every message through Subscriber#format_log, with a formatter that fails on a message
  # containing "poison" with an error that is not one of Subscriber::MESSAGE_ERRORS.
  class FormattingAppender < SemanticLogger::Subscriber
    attr_reader :written

    def initialize(**)
      super(formatter: lambda { |log, _appender|
        raise NoMethodError, "undefined method 'each' for an instance of String" if log.message.include?("poison")

        log.message
      }, **)
      @written = []
    end

    def log(log)
      @written << format_log(log)
    end
  end

  # Holds the worker thread before it writes a message containing "wait", once it has taken that
  # message off the queue, until the test opens the gate. Cannot reach its destination for a
  # message containing "unavailable", and fails with a FatalError for one containing "fatal".
  class GatedAppender < SimpleAppender
    attr_reader :gate, :waiting

    def initialize(**)
      super
      @gate    = Queue.new
      @waiting = Queue.new
    end

    def log(log)
      if log.message.include?("wait")
        waiting << log.message
        gate.pop
      end
      raise IOError, "destination unavailable" if log.message.include?("unavailable")
      raise FatalError, "fatal" if log.message.include?("fatal")

      super
    end
  end

  # Cannot reach its destination for a message containing "unavailable" the first `failures` times
  # it is written, alone or in a batch, and says that such a write wrote nothing.
  class ResendingAppender < BatchAppender
    def initialize(failures: 1, **)
      super(**)
      @failures = failures
    end

    def log(log)
      unavailable([log])
      super
    end

    def batch(logs)
      unavailable(logs)
      super
    end

    def wrote_nothing?(exception)
      exception.is_a?(IOError)
    end

    private

    def unavailable(logs)
      return unless @failures.positive? && logs.any? { |log| log.message.include?("unavailable") }

      @failures -= 1
      raise IOError, "destination unavailable"
    end
  end

  # A non-StandardError exception, used to exercise the fatal (non-retryable) path in #process.
  class FatalError < Exception; end # rubocop:disable Lint/InheritException

  describe SemanticLogger::QueueProcessor do
    let(:internal_logger) { SemanticLogger::Test::CaptureLogEvents.new }

    let(:appender) do
      a        = SimpleAppender.new
      a.logger = internal_logger
      a
    end

    # Track every processor whose worker thread is started so it can be stopped after each test.
    let(:started) { [] }

    after do
      started.each do |processor|
        thread = processor.instance_variable_get(:@thread)
        next unless thread

        thread.kill
        thread.join
      end
    end

    def build(**args)
      SemanticLogger::QueueProcessor.new(appender: appender, **args)
    end

    def start(**args)
      SemanticLogger::QueueProcessor.start(appender: appender, **args).tap { |p| started << p }
    end

    def request(command)
      SemanticLogger::QueueProcessor::Request.new(command)
    end

    # Runs the block with the back-offs of the processor's worker thread stubbed, so that they do not
    # wait: each one calls `on_wait`, when given, with the seconds it would have waited instead.
    def stub_back_off(processor, on_wait = nil, &)
      backoff = processor.instance_variable_get(:@backoff)
      backoff.stub(:wait, -> { on_wait&.call(backoff.retry_count) }, &)
    end

    include SignalTrapHelper

    def new_log(message: "hello world", level: :info, time: Time.now)
      log         = SemanticLogger::Log.new("User", level)
      log.message = message
      log.level   = level
      log.time    = time
      log
    end

    describe ".start" do
      it "starts the worker thread" do
        assert_predicate start, :active?
      end
    end

    describe "the worker thread" do
      it "is named after its appender, briefly enough for Linux to tell the workers apart" do
        processor = start
        processor.flush

        assert_equal "SL SimpleAppender", processor.thread.name
      end

      it "processes messages when the appender's internal logger is not named with a String" do
        internal_logger.name = :MyInternal
        processor            = start
        processor.log(new_log)

        assert processor.flush, "the worker thread did not reply to #flush"
        assert_equal 1, appender.events.count
      end

      it "is named SL when the appender's class has no name" do
        anonymous        = Class.new(SimpleAppender).new
        anonymous.logger = internal_logger
        processor        = SemanticLogger::QueueProcessor.start(appender: anonymous).tap { |p| started << p }
        processor.flush

        assert_equal "SL", processor.thread.name
      end

      it "processes messages, without a name, when Ruby rejects the name" do
        skip "Module#set_temporary_name needs Ruby 3.3" unless Module.method_defined?(:set_temporary_name)

        ["Bad\0Name", "Wide".encode("UTF-16LE")].each do |class_name|
          rejected        = Class.new(SimpleAppender) { set_temporary_name(class_name) }.new
          rejected.logger = internal_logger
          processor       = SemanticLogger::QueueProcessor.start(appender: rejected).tap { |p| started << p }
          processor.log(new_log)

          assert processor.flush, "the worker thread did not reply to #flush for #{class_name.inspect}"
          assert_equal 1, rejected.events.count
          assert_nil processor.thread.name
        end
      end
    end

    describe "#initialize" do
      it "creates a capped queue by default" do
        processor = build(max_queue_size: 100)

        assert_instance_of SizedQueue, processor.queue
        assert_predicate processor, :capped?
      end

      it "creates an uncapped queue when max_queue_size is -1" do
        processor = build(max_queue_size: -1)

        assert_instance_of Queue, processor.queue
        refute_predicate processor, :capped?
      end

      it "is not a batch processor by default" do
        refute_predicate build, :batch?
      end

      describe "batch" do
        it "raises when the appender does not implement #batch" do
          assert_raises(ArgumentError) do
            SemanticLogger::QueueProcessor.new(appender: PlainAppender.new, batch: true)
          end
        end

        it "is a batch processor for an appender that implements #batch" do
          batch_appender        = BatchAppender.new
          batch_appender.logger = internal_logger
          processor             = SemanticLogger::QueueProcessor.new(appender: batch_appender, batch: true)

          assert_predicate processor, :batch?
        end
      end
    end

    describe "#logger" do
      it "uses the appender's logger" do
        assert_equal internal_logger, build.logger
      end
    end

    describe "#log" do
      it "adds the message to the queue" do
        processor = build
        log       = new_log

        assert processor.log(log)
        assert_equal log, processor.queue.pop
      end

      it "drops messages when non_blocking and the queue is full" do
        processor = build(max_queue_size: 2, non_blocking: true, dropped_message_report_seconds: 0)

        2.times { processor.log(new_log) }

        assert_equal 2, processor.queue.size
        refute processor.log(new_log)
        assert_equal 2, processor.queue.size, "queue must not grow beyond its cap"
        assert_equal 1, processor.dropped_count
      end

      it "drops messages when non_blocking is enabled after the processor was created" do
        processor = build(max_queue_size: 1)
        processor.log(new_log)
        processor.non_blocking = true

        refute processor.log(new_log)
        assert_equal 1, processor.dropped_count
      end

      # Ruby does not allow a Mutex to be locked in a signal trap.
      it "drops messages in a signal trap when non_blocking and the queue is full, and counts them" do
        processor = build(max_queue_size: 1, non_blocking: true, dropped_message_report_seconds: 0)
        processor.log(new_log)

        logged = in_signal_trap { [processor.log(new_log), processor.log(new_log)] }

        assert_equal [false, false], logged
        assert_equal 2, processor.dropped_count
      end

      it "reports the messages dropped in a signal trap just after it" do
        processor = build(max_queue_size: 1, non_blocking: true, dropped_message_report_seconds: 0)
        processor.log(new_log)
        in_signal_trap { 2.times { processor.log(new_log) } }
        reported = -> { internal_logger.events.sum { |event| event.message[/\AAsync: Dropped (\d+)/, 1].to_i } }
        deadline = Time.now + 5
        sleep(0.01) until reported.call == 2 || Time.now > deadline

        assert_equal 2, reported.call
        assert_equal 2, processor.dropped_count
      end

      it "drops messages in a signal trap once the worker thread has stopped" do
        processor = build(max_queue_size: 1)
        processor.log(new_log)
        processor.instance_variable_set(:@stopped, true)

        logged = in_signal_trap { processor.log(new_log) }

        refute logged
        assert_equal 1, processor.dropped_count
      end
    end

    describe "#process_messages" do
      it "writes queued messages to the appender, then stops on close" do
        processor = build
        processor.queue << new_log(message: "one")
        processor.queue << new_log(message: "two", level: :warn)
        processor.queue << request(:close)
        processor.send(:process_messages)

        assert_equal 2, appender.events.count
        assert_equal "one", appender.events.first.message
        assert_equal :warn, appender.events.last.level
        assert_predicate appender, :closed
      end

      it "tracks the processed count" do
        processor = build
        processor.queue << new_log
        processor.queue << request(:close)
        processor.send(:process_messages)

        assert_equal 1, processor.processed_count
      end
    end

    describe "#process retry-with-backoff" do
      it "retries on StandardError up to async_max_retries, then stops" do
        processor = build(async_max_retries: 2)
        attempts  = 0
        boom      = lambda do
          attempts += 1
          raise "boom"
        end

        stub_back_off(processor, nil) do
          processor.stub(:process_messages, boom) do
            processor.send(:process)
          end
        end

        assert_equal 3, attempts, "expected initial attempt + 2 retries"
        assert_equal 2, processor.retry_count

        messages = internal_logger.events.map(&:message)
        retries  = messages.count { |m| m.include?("Restarting due to exception, retry") }

        assert_equal 2, retries
        assert(messages.any? { |m| m.include?("Stopping after 2 failed retries") })
      end

      it "reports that the worker thread is active once, not again on each restart" do
        processor = build(async_max_retries: 2)
        stub_back_off(processor, nil) do
          processor.stub(:process_messages, -> { raise "boom" }) do
            processor.send(:process)
          end
        end

        actives = internal_logger.events.count { |event| event.message == "Async: Appender thread active" }

        assert_equal 1, actives
      end

      it "retries indefinitely when async_max_retries is -1" do
        processor = build(async_max_retries: -1)
        attempts  = 0
        # Raise on the first 5 attempts, then return normally to end processing.
        flaky     = lambda do
          attempts += 1
          raise "boom" if attempts <= 5
        end

        stub_back_off(processor, nil) do
          processor.stub(:process_messages, flaky) do
            processor.send(:process)
          end
        end

        assert_equal 6, attempts
        messages = internal_logger.events.map(&:message)

        refute(messages.any? { |m| m.include?("Stopping after") }, "must not give up when retries are unlimited")
      end

      it "sleeps with an increasing back-off between retries" do
        processor = build(async_max_retries: 3)
        slept     = []

        stub_back_off(processor, ->(seconds) { slept << seconds }) do
          processor.stub(:process_messages, -> { raise "boom" }) do
            processor.send(:process)
          end
        end

        assert_equal [1, 2, 3], slept
      end

      it "resets the retry count after a message is processed successfully" do
        processor = build(async_max_retries: 5)
        3.times { processor.instance_variable_get(:@backoff).retry? }
        processor.queue << new_log
        processor.queue << request(:close)

        processor.send(:process_messages)

        assert_equal 0, processor.retry_count
      end

      it "stops immediately, without retrying, on a non-StandardError exception" do
        processor = build(async_max_retries: 5)
        attempts  = 0
        fatal     = lambda do
          attempts += 1
          raise FatalError, "fatal"
        end

        stub_back_off(processor, nil) do
          processor.stub(:process_messages, fatal) do
            processor.send(:process)
          end
        end

        assert_equal 1, attempts
        assert_equal 0, processor.retry_count
        assert(internal_logger.events.map(&:message).any? { |m| m.include?("fatal exception") })
      end
    end

    describe "a message that cannot be written" do
      describe "streaming" do
        let(:appender) do
          a        = PoisonedAppender.new
          a.logger = internal_logger
          a
        end

        it "discards only that message, without backing off" do
          processor = build
          processor.queue << new_log(message: "first")
          processor.queue << new_log(message: "poison")
          processor.queue << new_log(message: "last")
          processor.queue << request(:close)

          stub_back_off(processor, ->(_) { flunk "must not back off for a message error" }) do
            processor.send(:process)
          end

          assert_equal %w[first last], appender.events.map(&:message)
          assert_equal 2, processor.processed_count
          assert_equal 1, processor.failed_count
          assert_equal 0, processor.retry_count
          assert(internal_logger.events.any? { |event| event.message.include?("Discarded") })
        end

        it "reports the first discarded message, then at most one count per interval" do
          processor = build(dropped_message_report_seconds: 30)
          5.times { |i| processor.queue << new_log(message: "poison #{i}") }
          processor.queue << request(:close)
          processor.send(:process)

          reports = internal_logger.events.select { |event| event.message.include?("Discarded") }

          assert_equal 5, processor.failed_count
          assert_equal 1, reports.size
          assert_kind_of JSON::GeneratorError, reports.first.exception
        end

        it "reports the count of messages discarded since the previous report" do
          processor = build(dropped_message_report_seconds: 30)
          3.times { |i| processor.queue << new_log(message: "poison #{i}") }
          processor.queue << request(:close)
          processor.send(:process)
          processor.dropped_message_report_seconds = 0
          processor.queue << new_log(message: "poison")
          processor.queue << request(:close)
          processor.send(:process)

          reports = internal_logger.events.map(&:message).grep(/Discarded/)

          assert_equal 2, reports.size
          assert_match(/Discarded 3 log message\(s\) in the last \d+ seconds/, reports.last)
        end

        it "backs off when the destination's response cannot be parsed" do
          processor = build(async_max_retries: 0)
          appender.stub(:log, ->(_) { JSON.parse("<html>502 Bad Gateway</html>") }) do
            processor.queue << new_log
            processor.send(:process)
          end

          assert_equal 1, processor.failed_count
          assert_predicate processor, :stopped?
        end

        describe "when writing it overflows the stack" do
          let(:appender) do
            a        = StackOverflowAppender.new
            a.logger = internal_logger
            a
          end

          # On macOS a second stack overflow on the same thread crashes Ruby, so nothing more may be
          # written on a thread once it has overflowed.
          it "discards only that message, and carries on in a new thread" do
            processor = start
            %w[first deep last].each { |message| processor.log(new_log(message: message)) }

            assert processor.flush, "the flush must be answered by the new thread"
            assert_equal %w[first last], appender.events.map(&:message)
            assert_equal 1, processor.failed_count
            assert_equal 0, processor.retry_count
            refute_predicate processor, :stopped?
            assert_predicate processor, :active?

            overflowed = appender.threads[1]

            refute_same overflowed, appender.threads[2]
            refute_predicate overflowed, :alive?
          end

          # The thread that hands over assigns the new one to @thread after creating it. The new one must
          # not run before then: were it to overflow and hand over too, the thread it handed over to
          # would run unseen, beside the next one that #thread starts.
          it "carries on in one new thread after two overflows in a row" do
            processor = start

            assert processor.flush, "the worker thread should be processing messages"
            create       = Thread.method(:new)
            handing_over = nil
            # Delays the first hand-over between creating the new thread and assigning it.
            delay_assignment = lambda do |*args, &block|
              thread = create.call(*args, &block)
              unless handing_over
                handing_over = Thread.current
                sleep 0.2
              end
              thread
            end
            Thread.stub(:new, delay_assignment) do
              processor.log(new_log(message: "deep 1"))
              processor.log(new_log(message: "deep 2"))
              deadline = Time.now + 5
              sleep(0.01) until processor.failed_count == 2 || Time.now > deadline
            end

            assert_equal 2, processor.failed_count
            assert handing_over.join(5), "the first thread that overflowed should end once it has handed over"
            assert processor.flush, "the last new thread should be the worker thread"
            processor.thread
            messages = (1..10).map { |i| "m#{i}" }
            messages.each { |message| processor.log(new_log(message: message)) }

            assert processor.flush
            assert_equal messages, appender.events.map(&:message)
            assert_equal 1, appender.threads.last(10).uniq.size, "only one worker thread should write"
          end

          it "discards a batch that overflows, without splitting it on the same thread, then carries on" do
            processor = start(batch: true, batch_size: 100, batch_seconds: 60)
            %w[first deep last].each { |message| processor.log(new_log(message: message)) }

            assert processor.flush, "the flush must be answered by the new thread"
            assert_equal 1, appender.threads.size, "the batch must not be split up on the thread that overflowed"
            assert_equal 3, processor.failed_count

            processor.log(new_log(message: "after"))

            assert processor.flush
            assert_equal %w[after], appender.events.map(&:message)
            refute_same appender.threads.first, appender.threads.last
            refute_predicate processor, :stopped?
          end

          it "discards the rest of a batch being split once one part overflows" do
            processor = start(batch: true, batch_size: 100, batch_seconds: 60)
            calls     = 0
            appender.define_singleton_method(:batch) do |logs|
              calls += 1
              raise JSON::GeneratorError, "cannot serialize" if calls == 1
              raise SystemStackError, "stack level too deep" if logs.any? { |log| log.message.include?("deep") }

              logs.each { |log| events << log }
            end
            %w[deep second third fourth].each { |message| processor.log(new_log(message: message)) }

            assert processor.flush
            assert_equal 2, calls, "nothing more may be written on the thread that overflowed"
            assert_equal 4, processor.failed_count
            assert_empty appender.events
          end

          it "carries on in a new thread when an appender in the collection overflows" do
            collection = SemanticLogger::Appenders.new(internal_logger)
            collection << appender
            processor  = SemanticLogger::QueueProcessor.start(appender: collection).tap { |p| started << p }
            %w[first deep last].each { |message| processor.log(new_log(message: message)) }

            assert processor.flush
            assert_equal %w[first last], appender.events.map(&:message)
            assert_equal 1, processor.failed_count
          end
        end

        describe "when the formatter fails with any error" do
          let(:appender) do
            a        = FormattingAppender.new
            a.logger = internal_logger
            a
          end

          it "discards only that message, without backing off" do
            processor = build
            processor.queue << new_log(message: "first")
            processor.queue << new_log(message: "poison")
            processor.queue << new_log(message: "last")
            processor.queue << request(:close)

            stub_back_off(processor, ->(_) { flunk "must not back off for a message error" }) do
              processor.send(:process)
            end

            assert_equal %w[first last], appender.written
            assert_equal 1, processor.failed_count

            report = internal_logger.events.find { |event| event.message.include?("Discarded") }

            assert_kind_of SemanticLogger::Subscriber::FormatError, report.exception
            assert_kind_of NoMethodError, report.exception.cause
          end
        end

        it "asks the appender which errors are caused by the content of a message" do
          processor = build
          rejected  = Class.new(StandardError)
          appender.define_singleton_method(:message_error?) { |exception| exception.is_a?(rejected) }
          processor.queue << new_log(message: "rejected")
          processor.queue << new_log(message: "last")
          processor.queue << request(:close)

          original = appender.method(:log)
          appender.stub(:log, ->(log) { log.message == "rejected" ? raise(rejected) : original.call(log) }) do
            stub_back_off(processor, ->(_) { flunk "must not back off for a message error" }) do
              processor.send(:process)
            end
          end

          assert_equal %w[last], appender.events.map(&:message)
          assert_equal 1, processor.failed_count
        end
      end

      describe "batching" do
        let(:appender) do
          a        = PoisonedBatchAppender.new
          a.logger = internal_logger
          a
        end

        it "discards only that message, instead of the whole batch" do
          processor = start(batch: true, batch_size: 100, batch_seconds: 60)
          messages  = Array.new(9) { |i| "message #{i}" }.insert(4, "poison")
          messages.each { |message| processor.log(new_log(message: message)) }
          processor.flush

          delivered = appender.batches.flatten.map(&:message)

          assert_equal messages - ["poison"], delivered
          assert_equal 9, processor.processed_count
          assert_equal 1, processor.failed_count
          assert_predicate processor, :active?
        end

        describe "when the appender may have written part of the batch" do
          let(:appender) do
            a        = PoisonedItemBatchAppender.new
            a.logger = internal_logger
            a
          end

          it "discards the batch instead of writing any message twice" do
            processor = start(batch: true, batch_size: 100, batch_seconds: 60)
            messages  = Array.new(7) { |i| "message #{i}" } << "poison"
            messages.each { |message| processor.log(new_log(message: message)) }
            processor.flush

            assert_equal messages - ["poison"], appender.events.map(&:message)
            assert_equal 0, processor.processed_count
            assert_equal 8, processor.failed_count
            assert_predicate processor, :active?
          end
        end
      end
    end

    describe "a message the destination cannot take" do
      describe "streaming" do
        it "discards and reports that message, then backs off and carries on with the next one" do
          processor = build(async_max_retries: 1)
          failures  = 1
          original  = appender.method(:log)
          down      = lambda do |log|
            if failures.positive?
              failures -= 1
              raise IOError, "destination unavailable"
            end
            original.call(log)
          end
          processor.queue << new_log(message: "first")
          processor.queue << new_log(message: "second")
          processor.queue << request(:close)
          slept = []
          appender.stub(:log, down) do
            stub_back_off(processor, ->(seconds) { slept << seconds }) do
              processor.send(:process)
            end
          end

          assert_equal %w[second], appender.events.map(&:message)
          assert_equal [1], slept
          assert_equal 1, processor.processed_count
          assert_equal 1, processor.failed_count

          report = internal_logger.events.find { |event| event.message.include?("Discarded 1 log message(s)") }

          assert_kind_of IOError, report.exception
        end
      end

      describe "batching" do
        let(:appender) do
          a        = BatchAppender.new
          a.logger = internal_logger
          a
        end

        def write_batch_of(processor, messages)
          messages.each { |message| processor.queue << new_log(message: message) }
          processor.signal.set
          stub_back_off(processor, nil) { processor.send(:process) }
        end

        it "discards and reports the whole batch, then backs off" do
          processor = build(batch: true, batch_seconds: 60, async_max_retries: 0)
          appender.stub(:batch, ->(_) { raise IOError, "destination unavailable" }) do
            write_batch_of(processor, %w[first second third])
          end

          assert_equal 0, processor.processed_count
          assert_equal 3, processor.failed_count
          assert_predicate processor, :stopped?
          assert(internal_logger.events.any? { |event| event.message.include?("Discarded 3 log message(s)") })
        end

        it "counts only the messages not yet written when a batch being split cannot be written" do
          processor = build(batch: true, batch_seconds: 60, async_max_retries: 0)
          appender.define_singleton_method(:batch_all_or_nothing?) { true }
          calls    = 0
          original = appender.method(:batch)
          splitting = lambda do |logs|
            calls += 1
            raise JSON::GeneratorError, "cannot serialize" if calls == 1
            raise IOError, "destination unavailable" if calls == 3

            original.call(logs)
          end
          appender.stub(:batch, splitting) do
            write_batch_of(processor, %w[first second third fourth])
          end

          assert_equal([%w[first second]], appender.batches.map { |logs| logs.map(&:message) })
          assert_equal 2, processor.processed_count
          assert_equal 2, processor.failed_count
        end

        it "counts every message when the first half of a batch being split cannot be written" do
          processor = build(batch: true, batch_seconds: 60, async_max_retries: 0)
          appender.define_singleton_method(:batch_all_or_nothing?) { true }
          calls     = 0
          splitting = lambda do |_logs|
            calls += 1
            raise JSON::GeneratorError, "cannot serialize" if calls == 1

            raise IOError, "destination unavailable"
          end
          appender.stub(:batch, splitting) do
            write_batch_of(processor, %w[first second third fourth])
          end

          assert_equal 2, calls, "the second half must not be written once the destination is unavailable"
          assert_equal 0, processor.processed_count
          assert_equal 4, processor.failed_count
        end
      end
    end

    describe "a message the destination cannot take, when the appender says that the write wrote nothing" do
      let(:failures_before_written) { 1 }

      let(:appender) do
        a        = ResendingAppender.new(failures: failures_before_written)
        a.logger = internal_logger
        a
      end

      # Processes the messages on this thread, then closes, once the first back-off has queued the
      # close. Returns the back-offs, recorded instead of waiting.
      def process_all(processor, messages)
        messages.each { |message| processor.queue << new_log(message: message) }
        processor.signal&.set
        slept    = []
        back_off = lambda do |seconds|
          processor.queue << request(:close) if slept.empty?
          slept << seconds
        end
        stub_back_off(processor, back_off) { processor.send(:process) }
        slept
      end

      it "writes the message again once it has backed off, ahead of the next one" do
        processor = build(async_max_retries: 1)
        slept     = process_all(processor, %w[unavailable next])

        assert_equal %w[unavailable next], appender.events.map(&:message)
        assert_equal [1], slept
        assert_equal 2, processor.processed_count
        assert_equal 0, processor.failed_count
        assert_equal 0, processor.retry_count
      end

      it "writes the batch again, as it was, once it has backed off" do
        processor = build(batch: true, batch_seconds: 60, async_max_retries: 1)
        slept     = process_all(processor, %w[first unavailable third])

        assert_equal([%w[first unavailable third]], appender.batches.map { |logs| logs.map(&:message) })
        assert_equal [1], slept
        assert_equal 3, processor.processed_count
        assert_equal 0, processor.failed_count
      end

      describe "until it gives up" do
        let(:failures_before_written) { 10 }

        it "discards and reports the message once it has retried async_max_retries times" do
          processor = build(async_max_retries: 2)
          slept     = process_all(processor, %w[unavailable next])

          assert_equal [1, 2], slept
          assert_predicate processor, :stopped?
          assert_empty appender.events
          assert_equal 1, processor.failed_count
          messages = internal_logger.events.map(&:message)

          assert(messages.any? { |message| message.include?("Discarded 1 log message(s)") })
          assert(messages.any? { |message| message.include?("Stopping after 2 failed retries") })
        end

        # A report raising an exception that is not a StandardError ends the worker thread.
        it "is stopped before it reports the message it discards, so that waiting threads carry on" do
          internal_logger.define_singleton_method(:error) do |message, exception = nil|
            raise FatalError, "cannot report" if message.include?("Discarded")

            super(message, exception)
          end
          processor = build(async_max_retries: 0)
          processor.queue << new_log(message: "unavailable")
          processor.send(:process)

          assert_predicate processor, :stopped?
          assert_nil processor.instance_variable_get(:@held).release
        end
      end

      # Otherwise a message that the destination fails every time, such as one it answers with a 429
      # that never clears, would hold up the messages behind it until the thread gave up.
      describe "that the destination fails every time" do
        let(:failures_before_written) { 1_000 }

        it "discards the message once written again 3 times, and carries on with the next one" do
          processor = build(async_max_retries: 10)
          slept     = process_all(processor, %w[unavailable next])

          assert_equal [1, 2, 3, 4], slept
          assert_equal %w[next], appender.events.map(&:message)
          assert_equal 1, processor.failed_count
          assert_equal 0, processor.retry_count
          refute_predicate processor, :stopped?
        end

        it "discards the batch once written again 3 times, and carries on with the next one" do
          processor = build(batch: true, batch_seconds: 60, async_max_retries: 10)
          slept     = process_all(processor, %w[first unavailable third])
          processor.queue << new_log(message: "next")
          processor.queue << request(:close)
          processor.signal.set
          processor.send(:process)

          assert_equal [1, 2, 3, 4], slept
          assert_equal([%w[next]], appender.batches.map { |logs| logs.map(&:message) })
          assert_equal 3, processor.failed_count
          assert_equal 0, processor.retry_count
        end

        it "counts the times written again afresh for the next message held" do
          appender.instance_variable_set(:@failures, 5)
          processor = build(async_max_retries: 10)
          slept     = process_all(processor, %w[unavailable-first unavailable-second])

          # The first is discarded once written again 3 times. The second, held afresh, is written the
          # first time it is written again.
          assert_equal [1, 2, 3, 4, 5], slept
          assert_equal %w[unavailable-second], appender.events.map(&:message)
          assert_equal 1, processor.failed_count
        end
      end

      # An outage, during which the destination cannot be reached, then loses nothing until the worker
      # thread gives up after async_max_retries.
      describe "that never reached the destination" do
        let(:failures_before_written) { 6 }

        before { appender.define_singleton_method(:not_sent?) { |exception| exception.is_a?(IOError) } }

        it "writes the message again until written, without counting towards MAX_RESENDS" do
          processor = build(async_max_retries: 10)
          slept     = process_all(processor, %w[unavailable next])

          assert_equal [1, 2, 3, 4, 5, 6], slept
          assert_equal %w[unavailable next], appender.events.map(&:message)
          assert_equal 0, processor.failed_count
        end

        it "writes the batch again until written, without counting towards MAX_RESENDS" do
          processor = build(batch: true, batch_seconds: 60, async_max_retries: 10)
          slept     = process_all(processor, %w[first unavailable third])

          assert_equal [1, 2, 3, 4, 5, 6], slept
          assert_equal([%w[first unavailable third]], appender.batches.map { |logs| logs.map(&:message) })
          assert_equal 0, processor.failed_count
        end

        it "still discards and reports the message once it has retried async_max_retries times" do
          processor = build(async_max_retries: 4)
          slept     = process_all(processor, %w[unavailable next])

          assert_equal [1, 2, 3, 4], slept
          assert_predicate processor, :stopped?
          assert_empty appender.events
          assert_equal 1, processor.failed_count
        end
      end

      it "is written only once, by the parent process, after a fork" do
        skip "fork is not supported" unless Process.respond_to?(:fork)

        processor = start

        assert processor.flush, "the worker thread should be waiting for the next message"
        processor.instance_variable_get(:@held).hold([new_log(message: "held by the parent")], answered: true)
        reader, writer = IO.pipe
        pid            = fork do
          reader.close
          processor.reopen
          processor.log(new_log(message: "in the child"))
          processor.flush
          writer.write(appender.events.map(&:message).join(","))
          writer.close
          exit!(0)
        end
        writer.close
        Process.wait(pid)
        written_in_child = reader.read
        reader.close

        assert_equal "in the child", written_in_child
      end
    end

    # During an outage, each message the destination cannot take would otherwise wait out a longer
    # back-off than the one before.
    describe "a flush or close during an outage" do
      let(:failures_before_written) { 1_000 }

      let(:appender) do
        a        = ResendingAppender.new(failures: failures_before_written)
        a.logger = internal_logger
        a
      end

      # Submits the command on another thread, and returns its result and how long it took.
      def timed(processor, command)
        started  = Time.now
        thread   = Thread.new { processor.public_send(command) }

        assert thread.join(5), "the #{command} should not wait out the back-offs"
        [thread.value, Time.now - started]
      end

      it "ends the back-off under way, and discards the messages it cannot write instead of backing off" do
        processor = start
        5.times { |i| processor.log(new_log(message: "unavailable #{i}")) }
        deadline = Time.now + 5
        Thread.pass until processor.retry_count.positive? || Time.now > deadline

        assert_equal 1, processor.retry_count, "the worker thread should be backing off"
        flushed, seconds = timed(processor, :flush)

        assert flushed
        assert_operator seconds, :<, 0.5
        assert_equal 5, processor.failed_count
        assert_equal 1, processor.retry_count, "a failure while the flush waits should not count as a retry"
        refute_predicate processor, :stopped?
      end

      it "writes the messages the destination takes again, ahead of the flush" do
        appender.instance_variable_set(:@failures, 1)
        processor = start
        processor.log(new_log(message: "unavailable"))
        deadline = Time.now + 5
        Thread.pass until processor.retry_count.positive? || Time.now > deadline
        processor.log(new_log(message: "next"))

        assert_equal [true], timed(processor, :flush).first(1)
        # Sent again straight away, rather than after the back-off, which the flush ended.
        assert_equal %w[unavailable next], appender.events.map(&:message)
      end

      it "does not wait out the back-offs for an appender that does not say that its writes wrote nothing" do
        appender.define_singleton_method(:wrote_nothing?) { |_exception| false }
        processor = start
        5.times { |i| processor.log(new_log(message: "unavailable #{i}")) }
        flushed, seconds = timed(processor, :flush)

        assert flushed
        assert_operator seconds, :<, 0.5
        assert_equal 5, processor.failed_count
      end

      it "closes without waiting out the back-offs" do
        processor = start(batch: true, batch_size: 2, batch_seconds: 60)
        4.times { |i| processor.log(new_log(message: "unavailable #{i}")) }
        closed, seconds = timed(processor, :close)

        assert closed
        assert_operator seconds, :<, 0.5
        assert_equal 4, processor.failed_count
        assert_predicate appender, :closed
      end
    end

    describe "a command taken off the queue with a batch that cannot be written" do
      let(:appender) do
        a        = UnavailableBatchAppender.new
        a.logger = internal_logger
        a
      end

      def queue_batch_with(processor, command)
        3.times { processor.queue << new_log }
        processor.queue << command
        processor.signal.set
        command
      end

      it "flushes and replies before backing off" do
        processor = build(batch: true, batch_seconds: 60, async_max_retries: 0)
        flush     = queue_batch_with(processor, request(:flush))
        processor.send(:process)

        assert flush.wait { false }, "the flush was not answered"
        assert_predicate appender, :flushed
        assert_predicate processor, :stopped?
      end

      it "closes the appender and stops, instead of backing off" do
        processor = build(batch: true, batch_seconds: 60, async_max_retries: 5)
        close     = queue_batch_with(processor, request(:close))
        stub_back_off(processor, ->(_) { flunk "must not back off after closing" }) do
          processor.send(:process)
        end

        assert close.wait { false }, "the close was not answered"
        assert_predicate appender, :closed
        refute_predicate processor, :stopped?
        assert_equal 3, processor.failed_count
        assert(internal_logger.events.any? { |event| event.message.include?("Closed without writing 3 log messages") })
      end
    end

    describe "a command taken off the queue with a batch, that raises" do
      let(:appender) do
        a        = BatchAppender.new
        a.logger = internal_logger
        a
      end

      def process_batch_with(processor, *commands)
        processor.queue << new_log
        commands.each { |command| processor.queue << command }
        processor.signal.set
        processor.send(:process)
      end

      it "reports a close that failed, and stops" do
        processor = build(batch: true, batch_seconds: 60)
        appender.define_singleton_method(:close) { raise IOError, "cannot close" }
        process_batch_with(processor, request(:close))

        report = internal_logger.events.find { |event| event.message.include?("Failed to close the appender") }

        assert report, "the failed close should be reported"
        assert_kind_of IOError, report.exception
        refute(internal_logger.events.any? { |event| event.message.include?("Closed without writing") })
        assert_equal 1, processor.processed_count
      end

      it "reports a flush that failed before a close stopped it" do
        processor = build(batch: true, batch_seconds: 60)
        appender.define_singleton_method(:flush) { raise IOError, "cannot flush" }
        process_batch_with(processor, request(:flush), request(:close))

        report = internal_logger.events.find { |event| event.message.include?("Failed to flush the appender") }

        assert report, "the failed flush should be reported"
        assert_kind_of IOError, report.exception
        assert_predicate appender, :closed
        refute(internal_logger.events.any? { |event| event.message.include?("Closed without writing") })
      end

      it "returns from #flush" do
        processor = start(batch: true, batch_size: 100, batch_seconds: 60)
        3.times { processor.log(new_log) }
        flusher = Thread.new { processor.flush }

        assert flusher.join(5), "flush blocked after the batch could not be written"
        assert_predicate appender, :flushed
      end
    end

    # A request counted as waiting keeps the worker thread from backing off, so each must be counted
    # out exactly once, when it has run or will not.
    describe "the requests counted as waiting" do
      let(:appender) do
        a        = BatchAppender.new
        a.logger = internal_logger
        a
      end

      let(:backoff) { @processor.instance_variable_get(:@backoff) }

      # Returns a request counted as waiting, as #flush and #close submit one.
      def submitted(command)
        backoff.request_submitted
        SemanticLogger::QueueProcessor::Request.new(command) { backoff.request_done }
      end

      it "runs a flush that raised once, after a batch, and counts it out once" do
        @processor = build(batch: true, batch_seconds: 60)
        flushes    = []
        appender.define_singleton_method(:flush) do
          flushes << true
          raise IOError, "flush failed"
        end
        flush = submitted(:flush)
        submitted(:flush) # still on the queue

        assert_raises(IOError) { @processor.send(:write_batch_then_run, [new_log], [flush]) }
        assert_equal 1, flushes.size
        refute(flush.wait { false })
        assert_equal 1, backoff.instance_variable_get(:@requests).size
      end

      it "counts out a request skipped behind a close, which never runs" do
        @processor = build(batch: true, batch_seconds: 60)
        close      = submitted(:close)
        flush      = submitted(:flush)

        refute @processor.send(:write_batch_then_run, [new_log], [close, flush])
        refute_predicate flush, :ran?
        refute_predicate backoff, :requests_waiting?
      end

      # A request waiting keeps the worker thread from giving up after async_max_retries, so it stops
      # with a fatal error here.
      it "keeps counting a request still on the queue when the worker thread starts again" do
        appender        = GatedAppender.new
        appender.logger = internal_logger
        @processor      = SemanticLogger::QueueProcessor.start(appender: appender)
        started << @processor
        @processor.log(new_log(message: "wait fatal"))

        assert appender.waiting.pop(timeout: 5), "the worker thread should take the message off the queue"
        @processor.log(new_log(message: "wait second"))
        flusher = Thread.new { @processor.flush }
        Thread.pass until @processor.queue.size == 2
        worker = @processor.thread
        appender.gate << true

        assert worker.join(5), "the worker thread should stop"
        refute flusher.value, "the flush should stop waiting once the worker thread has stopped"
        @processor.reopen

        assert appender.waiting.pop(timeout: 5), "the new worker thread should take the next message"
        assert_predicate backoff, :requests_waiting?, "the flush on the queue should still be waiting"
        appender.gate << true

        assert @processor.flush
        refute_predicate backoff, :requests_waiting?
      ensure
        flusher&.kill
      end

      it "forgets the requests counted as waiting after a fork, with the queue of the parent process" do
        @processor = start
        submitted(:flush)
        @processor.instance_variable_get(:@inbox).instance_variable_set(:@pid, -1)
        @processor.reopen

        refute_predicate backoff, :requests_waiting?
      end
    end

    describe "a command whose appender method raises" do
      it "is answered before the error propagates" do
        processor = build(async_max_retries: 0)
        flush     = request(:flush)
        processor.queue << flush
        appender.stub(:flush, -> { raise "destination unavailable" }) do
          processor.send(:process)
        end

        refute(flush.wait { false })
        assert_predicate processor, :stopped?
      end
    end

    describe "a command submitted on the worker thread itself" do
      it "returns false at once, rather than waiting for the worker thread, which cannot reply" do
        results   = Queue.new
        processor = nil
        appender.define_singleton_method(:log) { |_log| results << [processor.flush, processor.close] }
        processor = start

        processor.log(new_log)

        assert_equal [false, false], results.pop(timeout: 5), "the worker thread waited for itself"
        refute appender.flushed
        refute appender.closed
        assert processor.flush
        assert_predicate appender, :flushed
      end
    end

    describe "after the worker thread stops" do
      it "stops waiting on #flush when the worker thread ends without replying" do
        processor = build
        processor.instance_variable_set(:@thread, Thread.new { sleep 0.1 })
        result  = nil
        flusher = Thread.new { result = processor.flush }

        assert flusher.join(5), "flush blocked after the worker thread ended"
        refute result
      end

      it "drops messages instead of blocking the calling thread" do
        processor = build(max_queue_size: 2, async_max_retries: 0)
        processor.stub(:process_messages, -> { raise "destination unavailable" }) do
          processor.send(:process)
        end

        assert_predicate processor, :stopped?

        results = nil
        thread  = Thread.new { results = Array.new(5) { processor.log(new_log) } }

        assert thread.join(2), "logging blocked after the worker thread stopped"
        assert_equal [true, true, false, false, false], results
        assert_equal 3, processor.dropped_count
      end

      # A larger queue would not help: nothing empties it.
      it "reports that the worker thread has stopped, rather than advise a larger queue" do
        processor = build(max_queue_size: 1, async_max_retries: 0, dropped_message_report_seconds: 0)
        processor.stub(:process_messages, -> { raise "destination unavailable" }) do
          processor.send(:process)
        end
        processor.log(new_log)

        refute processor.log(new_log)
        report = internal_logger.events.map(&:message).grep(/\AAsync: Dropped/).last

        assert_match(/worker thread has stopped/, report)
        refute_match(/max_queue_size/, report)
      end

      it "keeps queueing messages on a queue that is not capped, which is never full" do
        processor = build(max_queue_size: -1, async_max_retries: 0)
        processor.stub(:process_messages, -> { raise "destination unavailable" }) do
          processor.send(:process)
        end

        assert_predicate processor, :stopped?
        assert_equal [true, true, true], Array.new(3) { processor.log(new_log) }
        assert_equal 3, processor.queue.size
        assert_equal 0, processor.dropped_count
      end

      it "is not stopped while the worker thread is running" do
        refute_predicate start, :stopped?
      end
    end

    describe "a thread waiting for room on the full queue when the worker thread stops for good" do
      let(:appender) do
        a        = GatedAppender.new
        a.logger = internal_logger
        a
      end

      # Starts a processor whose worker thread holds an entry it cannot write until the test opens the
      # gate, then stops for good, leaving behind it a full queue.
      def start_full
        processor = start(max_queue_size: 1, async_max_retries: 0)
        processor.log(new_log(message: "wait unavailable"))

        assert appender.waiting.pop(timeout: 5), "the worker thread should take the entry off the queue"
        processor.log(new_log(message: "queued"))
        processor
      end

      # Waits until a thread is waiting for room on the queue.
      def wait_for_waiting(processor)
        deadline = Time.now + 5
        Thread.pass until processor.queue.num_waiting == 1 || Time.now > deadline

        assert_equal 1, processor.queue.num_waiting, "a thread should be waiting for room on the queue"
      end

      it "lets a log call carry on, dropping its entry, and keeps the queued entries" do
        processor = start_full
        worker    = processor.thread
        logging   = Thread.new { processor.log(new_log(message: "waiting")) }
        wait_for_waiting(processor)
        appender.gate << true

        assert logging.join(5), "the log call should not wait for ever"
        refute logging.value
        assert worker.join(5), "the worker thread should stop"
        assert_predicate processor, :stopped?
        assert_equal 1, processor.dropped_count
        processor.reopen

        assert processor.flush, "the new worker thread should answer the flush"
        assert_equal ["queued"], appender.events.map(&:message)
      ensure
        logging&.kill
      end

      # A flush that is waiting keeps the worker thread from backing off, and so from giving up after
      # async_max_retries, but not from stopping on a fatal error.
      it "lets a flush carry on, which returns false" do
        processor = start(max_queue_size: 1)
        processor.log(new_log(message: "wait fatal"))

        assert appender.waiting.pop(timeout: 5), "the worker thread should take the entry off the queue"
        processor.log(new_log(message: "queued"))
        flusher = Thread.new { processor.flush }
        wait_for_waiting(processor)
        appender.gate << true

        assert flusher.join(5), "the flush should not wait for ever"
        refute flusher.value
        assert_predicate processor, :stopped?
      ensure
        flusher&.kill
      end

      it "lets a flush carry on, which writes the queued entries, rather than wait for the worker thread to give up" do
        processor = start_full
        flusher   = Thread.new { processor.flush }
        wait_for_waiting(processor)
        appender.gate << true

        assert flusher.join(5), "the flush should not wait for ever"
        assert flusher.value
        assert_equal ["queued"], appender.events.map(&:message)
        assert_equal 1, processor.failed_count
        refute_predicate processor, :stopped?
      ensure
        flusher&.kill
      end

      # Ruby allows a Queue to wait in a signal trap, unlike a Mutex.
      it "lets a log call in a signal trap carry on, dropping its entry" do
        processor = start_full
        returned  = Queue.new
        opener    = Thread.new do
          deadline = Time.now + 5
          Thread.pass until processor.queue.num_waiting == 1 || Time.now > deadline
          appender.gate << true
          # Should the log call wait for ever, make room for it, so that the test fails rather than hang.
          processor.queue.pop unless returned.pop(timeout: 5)
        end
        logged = in_signal_trap { processor.log(new_log(message: "in the trap")) }
        returned << true

        refute logged, "the log call should drop its entry"
        assert_equal 1, processor.dropped_count
      ensure
        opener&.kill
      end
    end

    describe "a command run by the worker (Request#run)" do
      it "flushes the appender" do
        assert request(:flush).run(appender)
        assert_predicate appender, :flushed
      end

      it "closes the appender and signals processing to stop" do
        refute request(:close).run(appender)
        assert_predicate appender, :closed
      end

      it "warns and continues on an unknown command" do
        assert build.send(:run_command, request(:nope))
        assert(internal_logger.events.any? { |e| e.message.include?("Ignoring unknown command: nope") })
      end
    end

    describe "#check_lag" do
      it "does not warn within the threshold" do
        build(lag_threshold_s: 30).send(:check_lag, new_log(time: Time.now))

        assert_empty internal_logger.events
      end

      it "warns when the lag threshold is exceeded" do
        build(lag_threshold_s: 30).send(:check_lag, new_log(time: Time.now - 40))

        assert log = internal_logger.events.first
        assert_equal :warn, log.level
        assert_includes log.message, "fallen behind"
      end
    end

    describe "#flush and #close" do
      it "return false when the worker thread is not running" do
        processor = build

        refute processor.flush
        refute processor.close
        refute_predicate appender, :flushed
      end

      it "flush is performed by the worker thread" do
        processor = start

        assert processor.flush
        assert_predicate appender, :flushed
      end
    end

    # A custom appender may return any object from its own #logger. Reporting to one that cannot
    # take the reports must neither stop the worker thread nor raise into the calling thread.
    describe "an internal logger without the logging methods" do
      before { appender.logger = Object.new }

      it "does not stop the worker thread" do
        processor = start
        processor.log(new_log)

        assert processor.flush, "the worker thread did not reply to #flush"
        assert_equal 1, appender.events.count
      end

      it "stops processing once the queue is closed" do
        processor = build
        processor.queue.close

        refute processor.send(:process_messages)
      end

      it "drops messages when non_blocking and the queue is full" do
        processor = build(max_queue_size: 1, non_blocking: true, dropped_message_report_seconds: 0)
        processor.log(new_log)

        refute processor.log(new_log)
        assert_equal 1, processor.dropped_count
      end

      it "checks the lag" do
        assert_nil build(lag_threshold_s: 30).send(:check_lag, new_log(time: Time.now - 40))
      end

      it "submits a command while messages are queued" do
        processor = build
        processor.queue << new_log
        # Takes the message and runs the command once both are on the queue, so that #flush first
        # reports the message it found queued.
        worker = Thread.new do
          Thread.pass until processor.queue.size == 2
          processor.queue.pop
          processor.queue.pop.run(appender)
        end
        processor.instance_variable_set(:@thread, worker)

        assert processor.flush
        assert_predicate appender, :flushed
      ensure
        worker&.kill
      end

      it "answers a command it does not know" do
        assert build.send(:run_command, request(:nope))
      end
    end

    describe "an internal logger that takes only the message, such as a Ruby Logger" do
      let(:output) { StringIO.new }

      before { appender.logger = ::Logger.new(output) }

      it "is reported to" do
        build(lag_threshold_s: 30).send(:check_lag, new_log(time: Time.now - 40))

        assert_includes output.string, "fallen behind"
      end

      it "is reported to with the exception added to the message" do
        processor = build(async_max_retries: 0)
        processor.stub(:process_messages, -> { raise IOError, "destination unavailable" }) do
          processor.send(:process)
        end

        assert_predicate processor, :stopped?
        assert_includes output.string, "Async: Stopping after 0 failed retries, dropping new messages " \
                                       "-- IOError: destination unavailable"
      end
    end

    describe "#reopen" do
      let(:appender) do
        a        = GatedAppender.new
        a.logger = internal_logger
        a
      end

      # Logs a message that holds the worker thread once it has taken it off the queue.
      def hold_worker(processor)
        processor.log(new_log(message: "wait first"))

        assert appender.waiting.pop(timeout: 5), "the worker thread should take the message off the queue"
      end

      # Stops the worker thread, which cannot reach the destination, and waits for it to end.
      def stop_worker(processor)
        worker = processor.thread
        processor.log(new_log(message: "unavailable"))

        assert worker.join(5), "the worker thread should stop"
        assert_predicate processor, :stopped?
      end

      # Calls #reopen in a signal trap, and returns :reopened, or what it raised.
      def reopen_in_signal_trap(processor)
        in_signal_trap do
          processor.reopen
          :reopened
        end
      end

      it "keeps the worker thread and the queued entries, writing them in order ahead of new ones" do
        processor = start
        worker    = processor.thread
        hold_worker(processor)
        processor.log(new_log(message: "second"))
        processor.log(new_log(message: "third"))

        processor.reopen
        processor.log(new_log(message: "fourth"))
        appender.gate << true

        assert processor.flush, "the worker thread should answer the flush"
        assert_equal ["wait first", "second", "third", "fourth"], appender.events.map(&:message)
        assert_same worker, processor.thread
      end

      it "lets a log call waiting for room on the full queue carry on" do
        processor = start(max_queue_size: 1)
        hold_worker(processor)
        processor.log(new_log(message: "second"))
        logging = Thread.new { processor.log(new_log(message: "third")) }
        Thread.pass until logging.status == "sleep" || !logging.alive?

        processor.reopen
        appender.gate << true

        assert logging.value, "the log call should add its entry to the queue"
        assert processor.flush, "the worker thread should answer the flush"
        assert_equal ["wait first", "second", "third"], appender.events.map(&:message)
      ensure
        logging&.kill
      end

      it "starts the worker thread again once it has stopped, which writes the entries queued meanwhile" do
        processor = start(async_max_retries: 0)
        stop_worker(processor)
        processor.log(new_log(message: "queued meanwhile"))

        processor.reopen

        refute_predicate processor, :stopped?
        assert_predicate processor, :active?
        assert processor.flush, "the new worker thread should answer the flush"
        assert_equal ["queued meanwhile"], appender.events.map(&:message)
      end

      # Otherwise, while the destination is still unavailable, the new worker thread would back off as
      # long again, holding up the threads logging to it once its queue is full.
      it "carries on with the count of failures in a row, in a worker thread started once it has stopped" do
        processor = start(async_max_retries: 1)
        slept     = Queue.new
        stub_back_off(processor, ->(seconds) { slept << seconds }) do
          worker = processor.thread
          2.times { processor.log(new_log(message: "unavailable")) }

          assert worker.join(5), "the worker thread should stop"
          processor.reopen
          worker = processor.thread
          processor.log(new_log(message: "unavailable"))

          assert worker.join(5), "the new worker thread should stop at its first failure"
          assert_predicate processor, :stopped?
        end

        assert_equal [1], Array.new(slept.size) { slept.pop }
        processor.reopen
        processor.log(new_log(message: "after"))

        assert processor.flush, "the new worker thread should write the next entry"
        assert_equal ["after"], appender.events.map(&:message)
        assert_equal 0, processor.retry_count
      end

      it "starts counting failures afresh in a child process after a fork" do
        processor = start(async_max_retries: 1)
        worker    = processor.thread
        slept     = Queue.new
        stub_back_off(processor, ->(seconds) { slept << seconds }) do
          2.times { processor.log(new_log(message: "unavailable")) }

          assert worker.join(5), "the worker thread should stop"
          assert_equal 1, slept.pop(timeout: 5)
          assert_equal 1, processor.retry_count
          processor.instance_variable_get(:@inbox).instance_variable_set(:@pid, -1)
          processor.reopen

          assert_equal 0, processor.retry_count
          processor.log(new_log(message: "unavailable"))

          # A flush that is waiting would keep it from backing off.
          assert_equal 1, slept.pop(timeout: 5), "the new worker thread should back off"
          processor.log(new_log(message: "after"))

          assert processor.flush, "the new worker thread should carry on"
        end

        refute_predicate processor, :stopped?
        assert_equal ["after"], appender.events.map(&:message)
      end

      # An internal logger that holds the worker thread while it reports that it stopped: it pushes
      # the report to `reporting`, then waits for `resume`, for 5 seconds at most.
      def holding_internal_logger(reporting, resume)
        internal = SemanticLogger::Test::CaptureLogEvents.new
        internal.define_singleton_method(:error) do |message, exception = nil|
          if message.include?("Stopping")
            reporting << message
            resume.pop(timeout: 5)
          end
          super(message, exception)
        end
        internal
      end

      # A worker thread that has stopped no longer changes the state of the processor, so a new one
      # can start while it still reports that it stopped.
      it "starts the worker thread again while the one that stopped is still reporting it" do
        reporting       = Queue.new
        resume          = Queue.new
        appender.logger = holding_internal_logger(reporting, resume)
        processor       = start(async_max_retries: 0)
        worker          = processor.thread
        processor.log(new_log(message: "unavailable"))

        assert_match(/Stopping/, reporting.pop(timeout: 5))
        processor.log(new_log(message: "queued meanwhile"))
        processor.reopen

        refute_same worker, processor.thread
        refute_predicate processor, :stopped?
        assert_predicate worker, :alive?
        resume << true

        assert worker.join(5), "the worker thread that stopped should end once it has reported"
        refute_predicate processor, :stopped?
        processor.log(new_log(message: "after"))

        assert processor.flush, "the new worker thread should answer the flush"
        assert_equal ["queued meanwhile", "after"], appender.events.map(&:message)
      ensure
        resume << true
      end

      it "waits for the worker thread that stopped to end, so that its report comes first" do
        reporting       = Queue.new
        resume          = Queue.new
        appender.logger = holding_internal_logger(reporting, resume)
        processor       = start(async_max_retries: 0)
        worker          = processor.thread
        processor.log(new_log(message: "unavailable"))

        assert_match(/Stopping/, reporting.pop(timeout: 5))
        # Lets the worker thread finish its report once this thread waits for it in #reopen.
        reopening = Thread.current
        resumer   = Thread.new do
          Thread.pass until reopening.status == "sleep"
          resume << true
        end
        processor.reopen

        refute_predicate worker, :alive?
        assert processor.flush, "the new worker thread should answer the flush"
        reports = appender.logger.events.map(&:message).grep(/Stopping|Thread has stopped|thread active/)

        assert_match(/Stopping/, reports[-3])
        assert_equal ["Async: Thread has stopped", "Async: Appender thread active"], reports.last(2)
      ensure
        resume << true
        resumer&.join(5)
      end

      it "drops the entries that the parent process queued, in a child process after a fork" do
        skip "fork is not supported" unless Process.respond_to?(:fork)

        processor = start
        hold_worker(processor)
        processor.log(new_log(message: "second"))

        reader, writer = IO.pipe
        pid            = fork do
          reader.close
          processor.reopen
          processor.log(new_log(message: "in the child"))
          processor.flush
          writer.write(appender.events.map(&:message).join(","))
          writer.close
          exit!(0)
        end
        writer.close
        Process.wait(pid)
        written_in_child = reader.read
        reader.close
        appender.gate << true

        assert_equal "in the child", written_in_child
        assert processor.flush, "the worker thread should answer the flush"
        assert_equal ["wait first", "second"], appender.events.map(&:message)
      end

      # Ruby does not allow a Mutex to be locked in a signal trap.
      it "works in a signal trap, such as one that reopens the log files after a rotation" do
        skip "the USR1 signal is not available" unless Signal.list.key?("USR1")

        processor = start

        assert processor.flush, "the worker thread should be processing messages"
        assert_equal :reopened, reopen_in_signal_trap(processor)
        assert_predicate processor, :active?
        processor.log(new_log)

        assert processor.flush, "the worker thread should answer the flush"
        assert_equal 1, appender.events.count
      end

      it "starts the worker thread again in a signal trap while the one that stopped is still reporting it" do
        skip "the USR1 signal is not available" unless Signal.list.key?("USR1")

        reporting       = Queue.new
        resume          = Queue.new
        appender.logger = holding_internal_logger(reporting, resume)
        processor       = start(async_max_retries: 0)
        worker          = processor.thread
        processor.log(new_log(message: "unavailable"))

        assert_match(/Stopping/, reporting.pop(timeout: 5))
        processor.log(new_log(message: "queued meanwhile"))
        reopened   = reopen_in_signal_trap(processor)
        new_worker = processor.thread
        resume << true

        assert_equal :reopened, reopened
        refute_same worker, new_worker
        refute_predicate processor, :stopped?
        assert processor.flush, "the new worker thread should answer the flush"
        assert_equal ["queued meanwhile"], appender.events.map(&:message)
      end

      it "starts the worker thread again in a signal trap, which writes the entries queued meanwhile" do
        skip "the USR1 signal is not available" unless Signal.list.key?("USR1")

        processor = start(async_max_retries: 0)
        stop_worker(processor)
        processor.log(new_log(message: "queued meanwhile"))

        assert_equal :reopened, reopen_in_signal_trap(processor)
        refute_predicate processor, :stopped?
        assert processor.flush, "the new worker thread should answer the flush"
        assert_equal ["queued meanwhile"], appender.events.map(&:message)
      end

      # The queue of a child process after a fork is created again, which must work in a trap too.
      it "creates the queue again in a signal trap after a fork" do
        skip "the USR1 signal is not available" unless Signal.list.key?("USR1")

        processor = start
        processor.instance_variable_get(:@inbox).instance_variable_set(:@pid, -1)
        queue = processor.queue

        assert_equal :reopened, reopen_in_signal_trap(processor)
        refute_same queue, processor.queue
        assert_predicate queue, :closed?
        processor.log(new_log)

        assert processor.flush, "the new worker thread should answer the flush"
        assert_equal 1, appender.events.count
      end
    end

    describe "batch processing" do
      let(:appender) do
        a        = BatchAppender.new
        a.logger = internal_logger
        a
      end

      it "wakes the worker thread once batch_size is reached" do
        processor = build(batch: true, batch_size: 3, batch_seconds: 60)

        processor.log(new_log)

        refute_predicate processor.signal, :set?

        processor.log(new_log)

        refute_predicate processor.signal, :set?

        processor.log(new_log)

        assert_predicate processor.signal, :set?
      end

      it "delivers all queued messages to the appender via #batch" do
        processor = start(batch: true, batch_size: 3, batch_seconds: 60)

        5.times { processor.log(new_log) }
        # Flush acts as a barrier: by the time it returns, the queued logs have been batched.
        processor.flush

        assert batches = processor.appender.batches
        assert_equal 5, batches.sum(&:size)
      end

      it "stops the worker thread on close" do
        processor = start(batch: true, batch_size: 3, batch_seconds: 60)
        thread    = processor.instance_variable_get(:@thread)

        assert processor.close
        assert_predicate appender, :closed
        thread.join(1)

        refute_predicate thread, :alive?, "worker thread must terminate after close"
      end
    end
  end
end
