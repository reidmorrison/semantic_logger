require_relative "test_helper"

class QueueProcessorTest < Minitest::Test
  class SimpleAppender < SemanticLogger::Test::CaptureLogEvents
    def close
      @closed = true
    end

    def closed?
      @closed
    end

    def flush
      @flushed = true
    end

    def flushed?
      @flushed
    end
  end

  class BatchAppender < SimpleAppender
    attr_accessor :batches

    def batch(events)
      (@batches ||= []) << events
    end
  end

  describe SemanticLogger::QueueProcessor do
    let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }
    let(:appender) do
      appender        = SimpleAppender.new
      appender.logger = logger
      appender
    end
    let(:lag_check_interval) { 1_000 }
    let(:lag_threshold_s) { 30 }
    let(:log_time) { Time.now - 1 }
    let(:max_queue_size) { 1_000 }
    let(:batch) { false }
    let(:log) do
      log         = SemanticLogger::Log.new("User", :info)
      log.message = "hello world"
      log.time    = log_time
      log.level   = :info
      log
    end

    let(:subject) do
      SemanticLogger::QueueProcessor.new(
        appender:           appender,
        lag_check_interval: lag_check_interval,
        lag_threshold_s:    lag_threshold_s,
        async_max_retries:  2,
        batch:              batch,
        batch_size:         3,
        batch_seconds:      1,
        max_queue_size:     max_queue_size
      )
    end

    describe ".new" do
      describe "batch" do
        let(:batch) { true }

        it "checks for non-batch appender attempts" do
          assert_raises(ArgumentError) { subject }
        end
      end

      it "creates a capped queue" do
        assert_instance_of SizedQueue, subject.queue
        assert_equal true, subject.capped?
      end

      describe "infinite max_queue_size" do
        let(:max_queue_size) { -1 }

        it "creates a capped queue" do
          assert_instance_of Queue, subject.queue
          assert_equal false, subject.capped?
        end
      end
    end

    describe "log" do
      it "adds the message to queue" do
        subject.log(log)
        assert message = subject.queue.pop
        assert_equal message, log
      end
    end

    describe "#process" do
      it "processes messages from the queue" do
        subject.queue << log
        subject.queue << { command: :close }
        subject.send(:process)

        assert_equal 1, appender.events.count
      end

      it "logs messages" do
        subject.queue << log
        subject.queue << { command: :close }
        subject.send(:process)

        assert messages = logger.events.collect(&:message)
        assert_equal 2, messages.count, messages
        assert_includes messages[0], "Processing messages"
        assert_includes messages[1], "Stopped processing messages"
      end

      it "retries on standard error" do
        subject.stub(:process_messages, -> { raise StandardError, "Standard" }) do
          subject.send(:process)
        end
        assert messages = logger.events.collect(&:message)
        assert_equal 5, messages.count, messages
        assert_includes messages[0], "Processing messages"
        assert_includes messages[1], "Sleeping 1 second(s). Retry: 1"
        assert_includes messages[2], "Sleeping 2 second(s). Retry: 2"
        assert_includes messages[3], "Stopping, exhausted 2 retries"
        assert_includes messages[4], "Stopped processing messages"
      end

      it "exits on exception" do
        subject.stub(:process_messages, -> { raise Exception, "Exception" }) do
          subject.send(:process)
        end
        assert messages = logger.events.collect(&:message)
        assert_equal 3, messages.count, messages
        assert_includes messages[0], "Processing messages"
        assert_includes messages[1], "Stopping due to a fatal exception"
        assert_includes messages[2], "Stopped processing messages"
      end
    end

    describe "#process_messages" do
      it "processes close command" do
        subject.queue << { command: :close }
        subject.send(:process_messages)
        assert appender.closed?

        assert_nil logger.events
      end

      it "processes messages" do
        subject.queue << log
        subject.queue << { command: :close }
        subject.send(:process_messages)

        assert_equal 1, appender.events.count
        assert log = appender.events.first
        assert_equal :info, log.level, -> { log.ai }
        assert_includes log.message, "hello world"
      end

      it "processes multiple messages" do
        subject.queue << log
        log2         = log.dup
        log2.level   = :warn
        log2.message = "oh no"
        subject.queue << log2
        subject.queue << { command: :close }
        subject.send(:process_messages)

        assert_equal 2, appender.events.count
        assert log = appender.events.last
        assert_equal :warn, log.level, -> { log.ai }
        assert_includes log.message, "oh no"
      end

      it "resets retry count" do
        subject.instance_variable_set(:@retry_count, 30)
        assert_equal 30, subject.retry_count
        subject.queue << log
        subject.queue << { command: :close }
        subject.send(:process_messages)
        assert_equal 0, subject.retry_count
      end
    end

    describe "#flush" do
      it "successful when running" do
        subject.send(:create_thread)
        assert_equal true, subject.flush
        assert appender.flushed?
      end

      it "false if not running" do
        assert_equal false, subject.flush
        refute appender.flushed?
      end
    end

    describe "#close" do
      it "successful when running" do
        subject.send(:create_thread)
        assert_equal true, subject.close
        assert appender.closed?
      end

      it "false if not running" do
        assert_equal false, subject.close
        refute appender.closed?
      end
    end

    describe "#process_command" do
      it "logs invalid command" do
        assert_equal true, subject.send(:process_command, command: :blah)
        assert log = logger.events.first
        assert_equal :warn, log.level
        assert_includes log.message, "Ignoring unknown command: blah"
      end
    end

    describe "#check_lag" do
      it "logs warning when lag is exceeded" do
        subject.send(:check_lag, log)
        assert_nil logger.events
      end

      describe "with very old message" do
        let(:log_time) { Time.now - 40 }

        it "logs warning when lag is exceeded" do
          subject.send(:check_lag, log)
          assert log = logger.events.first
          assert_equal :warn, log.level
          assert_includes log.message, "Fallen behind by"
        end
      end
    end

    describe "#logger" do
      it "uses appenders loggeapr" do
        assert_equal logger, subject.logger
      end
    end

    describe "batch appender" do
      let(:batch) { true }
      let(:appender) do
        appender        = BatchAppender.new
        appender.logger = logger
        appender
      end

      describe "#batch?" do
        it "is a batch" do
          assert_equal true, subject.batch?
        end
      end

      describe "#log" do
        it "adds the message to queue" do
          subject.log(log)
          assert message = subject.queue.pop
          assert_equal message, log
        end

        it "raises signal at batch_size" do
          subject.log(log)
          refute subject.signal.set?

          subject.log(log)
          refute subject.signal.set?

          subject.log(log)
          assert subject.signal.set?
        end
      end

      describe "#process_messages_in_batches" do
        it "sends a partial batch" do
          subject.queue << log
          subject.queue << { command: :close }
          subject.send(:process_messages_in_batches)

          assert_equal [[log]], appender.batches
        end

        it "sends a full batch" do
          3.times { subject.queue << log }
          subject.queue << { command: :close }
          subject.send(:process_messages_in_batches)

          assert_equal [[log, log, log]], appender.batches
        end

        it "sends full and partial batch" do
          4.times { subject.queue << log }
          subject.queue << { command: :close }
          subject.send(:process_messages_in_batches)

          assert_equal [[log, log, log], [log]], appender.batches
        end

        it "sends 2 full batches" do
          6.times { subject.queue << log }
          subject.queue << { command: :close }
          subject.send(:process_messages_in_batches)

          assert_equal [[log, log, log], [log, log, log]], appender.batches
        end
      end

      describe "#send_command" do
        it "wakes up thread immediately" do
          assert_equal true, subject.batch?
          thread = Thread.new do
            message = subject.queue.pop
            message[:reply_queue] << true
          end
          subject.stub(:active?, true) do
            subject.send(:send_command, command: :close)
          end

          assert subject.signal.set?
          thread.join
        end
      end
    end
  end
end
