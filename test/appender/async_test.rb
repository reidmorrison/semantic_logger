require_relative "../test_helper"

module Appender
  class AsyncTest < Minitest::Test
    describe SemanticLogger::Appender::Async do
      include InMemoryAppenderHelper

      describe "with capped queue" do
        let :added_appender do
          SemanticLogger.add_appender(appender: appender, async: true)
        end

        it "uses the async proxy" do
          assert_instance_of SemanticLogger::Appender::Async, added_appender
        end

        it "logs message immediately" do
          logger.info("hello world")

          assert log = log_message
          assert_equal "hello world", log.message
        end

        it "uses an capped queue" do
          assert_instance_of SizedQueue, added_appender.queue
        end
      end

      describe "with uncapped queue" do
        let :added_appender do
          SemanticLogger.add_appender(appender: appender, async: true, max_queue_size: -1)
        end

        it "uses the async proxy" do
          assert_instance_of SemanticLogger::Appender::Async, added_appender
        end

        it "uses an uncapped queue" do
          assert_instance_of Queue, added_appender.queue
        end
      end

      describe "non_blocking" do
        # Records warnings logged to the internal logger.
        let :recording_logger do
          Class.new do
            attr_reader :warnings

            def initialize
              @warnings = []
            end

            def warn(message)
              @warnings << message
            end

            def trace(*)
            end

            def name
              "Test"
            end
          end.new
        end

        it "is disabled by default" do
          proxy = SemanticLogger::Appender::Async.new(appender: appender, max_queue_size: 2)

          refute_predicate proxy, :non_blocking?
        ensure
          proxy&.close
        end

        it "cannot drop messages on an uncapped queue" do
          proxy = SemanticLogger::Appender::Async.new(appender: appender, max_queue_size: -1, non_blocking: true)

          refute_predicate proxy, :non_blocking?, "an uncapped queue cannot drop messages"
        ensure
          proxy&.close
        end

        it "drops messages instead of blocking when the queue is full" do
          proxy = SemanticLogger::Appender::Async.new(
            appender:                       appender,
            max_queue_size:                 2,
            non_blocking:                   true,
            dropped_message_report_seconds: 0
          )

          assert_predicate proxy, :non_blocking?
          proxy.logger = recording_logger

          # Stop the worker thread so the queue is not drained while we fill it.
          worker = proxy.instance_variable_get(:@thread)
          worker.kill
          worker.join

          log = SemanticLogger::Log.new("Test", :info)
          proxy.log(log) # queue size 1
          proxy.log(log) # queue size 2 (full)

          assert_equal 2, proxy.queue.size

          # Further messages must be dropped, not block, and not raise.
          proxy.log(log)
          proxy.log(log)

          assert_equal 2, proxy.queue.size, "queue must not grow beyond its cap"
          refute_empty recording_logger.warnings
          assert_match(/Dropped \d+ log messages/, recording_logger.warnings.last)
        ensure
          proxy&.queue&.clear
        end
      end
    end
  end
end
