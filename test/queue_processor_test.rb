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
    end

    describe "#process_messages" do
      it "writes queued messages to the appender, then stops on close" do
        processor = build
        processor.queue << new_log(message: "one")
        processor.queue << new_log(message: "two", level: :warn)
        processor.queue << {command: :close}
        processor.send(:process_messages)

        assert_equal 2, appender.events.count
        assert_equal "one", appender.events.first.message
        assert_equal :warn, appender.events.last.level
        assert_predicate appender, :closed
      end

      it "tracks the processed count" do
        processor = build
        processor.queue << new_log
        processor.queue << {command: :close}
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
        processor.queue << {command: :close}

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

    describe "#process_command" do
      it "flushes the appender" do
        processor = build

        assert processor.send(:process_message, command: :flush)
        assert_predicate appender, :flushed
      end

      it "closes the appender and signals processing to stop" do
        processor = build

        refute processor.send(:process_message, command: :close)
        assert_predicate appender, :closed
      end

      it "warns and continues on an unknown command" do
        processor = build

        assert processor.send(:process_message, command: :nope)
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
