require_relative "test_helper"

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

        processor.stub(:sleep, nil) do
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

      it "retries indefinitely when async_max_retries is -1" do
        processor = build(async_max_retries: -1)
        attempts  = 0
        # Raise on the first 5 attempts, then return normally to end processing.
        flaky     = lambda do
          attempts += 1
          raise "boom" if attempts <= 5
        end

        processor.stub(:sleep, nil) do
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

        processor.stub(:sleep, ->(seconds) { slept << seconds }) do
          processor.stub(:process_messages, -> { raise "boom" }) do
            processor.send(:process)
          end
        end

        assert_equal [1, 2, 3], slept
      end

      it "resets the retry count after a message is processed successfully" do
        processor = build(async_max_retries: 5)
        processor.instance_variable_set(:@retry_count, 3)
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

        processor.stub(:sleep, nil) do
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

          processor.stub(:sleep, ->(_) { flunk "must not back off for a message error" }) do
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

        it "backs off, instead of discarding, when the destination's response cannot be parsed" do
          processor = build(async_max_retries: 0)
          appender.stub(:log, ->(_) { JSON.parse("<html>502 Bad Gateway</html>") }) do
            processor.queue << new_log
            processor.send(:process)
          end

          assert_equal 0, processor.failed_count
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

            processor.stub(:sleep, ->(_) { flunk "must not back off for a message error" }) do
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
            processor.stub(:sleep, ->(_) { flunk "must not back off for a message error" }) do
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
        processor.stub(:sleep, ->(_) { flunk "must not back off after closing" }) do
          processor.send(:process)
        end

        assert close.wait { false }, "the close was not answered"
        assert_predicate appender, :closed
        refute_predicate processor, :stopped?
        assert(internal_logger.events.any? { |event| event.message.include?("Closed without writing 3 log messages") })
      end

      it "returns from #flush" do
        processor = start(batch: true, batch_size: 100, batch_seconds: 60)
        3.times { processor.log(new_log) }
        flusher = Thread.new { processor.flush }

        assert flusher.join(5), "flush blocked after the batch could not be written"
        assert_predicate appender, :flushed
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

      it "is not stopped while the worker thread is running" do
        refute_predicate start, :stopped?
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
        assert request(:nope).run(appender)
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
