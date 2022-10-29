require_relative "../test_helper"

module Appender
  class AsyncTest < Minitest::Test
    describe SemanticLogger::Appender::Async do
      let(:log) do
        log         = SemanticLogger::Log.new("User", :info)
        log.message = "hello world"
        log.level   = :info
        log
      end

      let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }

      let(:appender) do
        appender        = SemanticLogger::Test::CaptureLogEvents.new
        appender.logger = logger
        appender
      end

      let(:subject) do
        SemanticLogger::Appender::Async.new(appender: appender, async_max_retries: 2)
      end

      describe ".new" do
        it "starts a processor" do
          assert_equal true, subject.active?
        end

        it "is not closed" do
          assert_equal false, subject.closed?
        end
      end

      describe "#log" do
        it "calls log on the processor" do
          assert_equal true, subject.log(log)
          assert_equal log, subject.queue.pop
        end
      end

      describe "#flush" do
        it "calls flush on the processor" do
          subject.send(:processor).stub(:flush, true) do
            assert_equal true, subject.flush
          end
          assert_equal false, subject.closed?
        end
      end

      describe "#close" do
        it "calls close on the processor" do
          subject.send(:processor).stub(:close, true) do
            assert_equal true, subject.close
          end
          assert_equal true, subject.closed?
        end
      end

      describe "#reopen" do
        it "closes before reopening" do
          called = false
          subject.send(:processor).stub(:close, -> { called = true }) do
            assert_equal true, subject.reopen
          end
          assert called, "Did not call close on processor first"
          assert_equal false, subject.closed?
          assert_equal true, subject.active?
        end

        it "reopens a closed processor" do
          called = nil
          subject.close
          subject.send(:processor).stub(:close, -> { called = true }) do
            assert_equal true, subject.reopen
          end
          refute called, "Called close on closed processor"
          assert_equal false, subject.closed?
          assert_equal true, subject.active?
        end
      end
    end
  end
end
