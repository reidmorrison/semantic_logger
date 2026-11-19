require_relative "../test_helper"
require_relative "../signal_trap_helper"

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

      describe "#formatter=" do
        let(:io) { StringIO.new }
        let(:appender) { SemanticLogger::Appender::IO.new(io) }
        let(:added_appender) { SemanticLogger.add_appender(appender: appender, async: true) }

        it "changes the wrapped appender's formatter while it is running" do
          logger.info("before")
          SemanticLogger.flush
          added_appender.formatter = :json

          assert_instance_of SemanticLogger::Formatters::Json, appender.formatter
          assert_same appender.formatter, added_appender.formatter

          logger.info("after")
          SemanticLogger.flush
          before, after = io.string.lines

          assert_match(/ I .* TestLogger -- before$/, before)
          assert_equal "after", JSON.parse(after)["message"]
        end

        it "restores the wrapped appender's default formatter when set to nil" do
          added_appender.formatter = :json
          added_appender.formatter = nil

          assert_instance_of SemanticLogger::Formatters::Default, appender.formatter
        end

        describe "in batch mode" do
          let(:appender) do
            Class.new(SemanticLogger::Subscriber) do
              attr_reader :formatted

              def batch(logs)
                @formatted = format_batch(logs)
              end
            end.new
          end
          let(:added_appender) { SemanticLogger.add_appender(appender: appender, batch: true) }

          it "formats the batch with the new formatter on the worker thread" do
            added_appender.formatter = :json

            assert_predicate added_appender, :batch?
            logger.info("hello")
            SemanticLogger.flush

            entries = JSON.parse(appender.formatted)

            assert_equal(["hello"], entries.map { |entry| entry["message"] })
          end
        end
      end

      describe "#inspect" do
        it "shows the wrapped appender's own #inspect, but not the instance variables" do
          batch_appender = InMemoryBatchAppender.new
          batch_appender.instance_variable_set(:@password, "s3cr3t")
          batch_appender.define_singleton_method(:inspect_details) { %(queue_name="logs") }
          proxy = SemanticLogger::Appender::Async.new(appender: batch_appender, batch: true, batch_seconds: 60)
          proxy.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "card 4111" })
          expected = /\A#<SemanticLogger::Appender::Async:\S+ batch=true appender=#<InMemoryBatchAppender:\S+ (.*)>>\z/

          assert_match expected, proxy.inspect
          assert_equal %(queue_name="logs"), proxy.inspect[expected, 1]
        ensure
          proxy&.close
        end
      end

      describe "#reopen" do
        include SignalTrapHelper

        # Holds the worker thread while it writes a message, until the test opens the gate, and
        # records each message written and each reopen in `history`. A reopen locks a Mutex, as
        # connecting with a timeout does, which Ruby does not allow in a signal trap.
        let(:gated) do
          Class.new(SemanticLogger::Subscriber) do
            def gate = @gate ||= Queue.new
            def writing = @writing ||= Queue.new
            def history = @history ||= []

            def log(log)
              writing << true
              gate.pop
              history << log.message
            end

            def reopen
              Mutex.new.synchronize { nil }
              history << "reopen"
            end
          end.new
        end

        let(:proxy) { SemanticLogger::Appender::Async.new(appender: gated) }

        after do
          gated.gate << true
          proxy.close
        end

        it "does not reopen the appender while the worker thread is writing to it" do
          proxy.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "writing" })

          assert gated.writing.pop(timeout: 5), "the worker thread should be writing"
          proxy.reopen

          assert_empty gated.history, "the appender should not be reopened while it is writing"
          gated.gate << true

          assert proxy.flush
          assert_equal %w[writing reopen], gated.history
        end

        it "can be called in a signal trap, from which it does not reopen the appender" do
          reopened = in_signal_trap do
            proxy.reopen
            :reopened
          end

          assert_equal :reopened, reopened
          assert proxy.flush
          assert_equal %w[reopen], gated.history
        end
      end

      describe "#reopen when the appender cannot be reopened" do
        # Records what the worker thread reports about the appender.
        let(:internal_logger) { SemanticLogger::Test::CaptureLogEvents.new }

        # Cannot be reopened, as the :udp appender cannot once its server's name no longer resolves.
        let :appender do
          appender = Class.new(SemanticLogger::Test::CaptureLogEvents) do
            def reopen
              raise SocketError, "getaddrinfo: nodename nor servname provided, or not known"
            end
          end.new
          appender.logger = internal_logger
          appender
        end

        let(:added_appender) { SemanticLogger.add_appender(appender: appender, async: true, batch: false) }

        # Removed here, rather than left to InMemoryAppenderHelper, which can skip one, since a later
        # test that forks would then report that it cannot be reopened.
        after { SemanticLogger.remove_appender(added_appender) }

        def reopen_report
          internal_logger.events.find { |event| event.message.include?("Failed to reopen the appender") }
        end

        it "starts the worker thread again, which reports the appender's error and carries on" do
          worker = added_appender.thread
          worker.kill
          worker.join
          added_appender.reopen

          assert_predicate added_appender, :active?
          logger.info("after the reopen")
          SemanticLogger.flush

          assert_equal ["after the reopen"], appender.events.map(&:message)
          assert_kind_of SocketError, reopen_report&.exception
        end

        it "is reported by the worker thread, which SemanticLogger.reopen starts again" do
          worker = added_appender.thread
          worker.kill
          worker.join
          SemanticLogger.reopen(force: true)
          # Returns once the appender has been reopened, which comes ahead of the flush.
          SemanticLogger.flush

          assert_kind_of SocketError, reopen_report&.exception
          assert_predicate added_appender, :active?
        end

        it "has a worker thread in the child process after a fork, which writes the child's entries" do
          skip "fork is not supported" unless Process.respond_to?(:fork)

          added_appender
          reader, writer = IO.pipe
          pid            = fork do
            reader.close
            logger.info("in the child")
            SemanticLogger.flush
            result = [added_appender.active?, appender.events.map(&:message), reopen_report&.exception&.class]
            writer.write(result.inspect)
            writer.close
            exit!(0)
          end
          writer.close
          Process.wait(pid)
          from_child = reader.read
          reader.close

          assert_equal [true, ["in the child"], SocketError].inspect, from_child
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

      describe "stats" do
        it "reports operational statistics" do
          proxy = SemanticLogger::Appender::Async.new(appender: appender, max_queue_size: 100)
          stats = proxy.stats

          assert_equal appender.name, stats[:name]
          assert stats[:async]
          assert stats[:capped]
          assert_equal 100, stats[:max_queue_size]
          assert_equal 0, stats[:dropped]
          assert_equal 0, stats[:failed]
          assert_kind_of Integer, stats[:queue_size]
          assert_kind_of Integer, stats[:processed]
        ensure
          proxy&.close
        end

        it "reports nil max_queue_size for an uncapped queue" do
          proxy = SemanticLogger::Appender::Async.new(appender: appender, max_queue_size: -1)
          stats = proxy.stats

          refute stats[:capped]
          assert_nil stats[:max_queue_size]
        ensure
          proxy&.close
        end

        it "counts dropped messages" do
          appender.logger = SemanticLogger::Test::CaptureLogEvents.new
          proxy           = SemanticLogger::Appender::Async.new(
            appender:                       appender,
            max_queue_size:                 2,
            non_blocking:                   true,
            dropped_message_report_seconds: 0
          )

          # Stop the worker thread so the queue is not drained while we fill it.
          worker = proxy.thread
          worker.kill
          worker.join

          log = SemanticLogger::Log.new("Test", :info)
          4.times { proxy.log(log) }

          assert_equal 2, proxy.stats[:dropped]
          reports = appender.logger.events.map(&:message)

          assert_equal 2, reports.grep(/\AAsync: Dropped 1 log messages .* \(max_queue_size: 2\)/).size, reports.inspect
        ensure
          proxy&.queue&.clear
        end

        it "counts messages discarded because their content could not be written" do
          appender.logger = SemanticLogger::Test::CaptureLogEvents.new
          proxy           = SemanticLogger::Appender::Async.new(appender: appender)
          appender.stub(:log, ->(_) { raise JSON::GeneratorError, "cannot serialize" }) do
            2.times { proxy.log(SemanticLogger::Log.new("Test", :info)) }
            proxy.flush
          end

          assert_equal 2, proxy.failed_count
          assert_equal 2, proxy.stats[:failed]
        ensure
          proxy&.close
        end
      end

      describe "with a payload nested too deeply for JSON" do
        it "writes the event and keeps the worker thread running" do
          output = StringIO.new
          proxy  = SemanticLogger::Appender::Async.new(
            appender: SemanticLogger::Appender::IO.new(output, formatter: :json)
          )
          worker = proxy.thread

          nested = 1
          100_000.times { nested = [nested] }
          deep         = SemanticLogger::Log.new("Test", :info)
          deep.message = "deep"
          deep.payload = {params: nested}
          proxy.log(deep)

          # Wait without #flush, which would block forever if the worker had stopped.
          deadline = Time.now + 10
          sleep(0.01) while output.string.empty? && worker.alive? && Time.now < deadline

          assert_predicate worker, :alive?

          proxy.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "after" })
          proxy.flush

          messages = output.string.lines.map { |line| JSON.parse(line)["message"] }

          assert_equal %w[deep after], messages
        ensure
          proxy&.close
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
          worker = proxy.thread
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

      # The async proxy in batch mode (previously the removed Appender::AsyncBatch class).
      describe "batch mode" do
        let :appender do
          InMemoryBatchAppender.new
        end

        describe "with default batch_size" do
          let :added_appender do
            SemanticLogger.add_appender(appender: appender, batch: true)
          end

          it "uses an async proxy in batch mode" do
            assert_instance_of SemanticLogger::Appender::Async, added_appender
            assert_predicate added_appender, :batch?
          end

          it "logs messages after a flush" do
            logger.info("hello world1")

            refute appender.message

            logger.info("hello world2")

            refute appender.message

            logger.info("hello world3")

            refute appender.message

            # Calls flush
            assert logs = log_message
            assert_equal 3, logs.size, logs
            assert_equal "hello world1", logs[0].message
            assert_equal "hello world2", logs[1].message
            assert_equal "hello world3", logs[2].message
          end
        end

        # :batch_size, :batch_seconds
        describe "with batch_size 1" do
          let :added_appender do
            SemanticLogger.add_appender(appender: appender, batch: true, batch_size: 1)
          end

          it "uses an async proxy in batch mode" do
            assert_instance_of SemanticLogger::Appender::Async, added_appender
            assert_predicate added_appender, :batch?
          end

          it "logs message immediately" do
            logger.info("hello world")

            assert logs = log_message
            assert_equal 1, logs.size, logs
            assert_equal "hello world", logs.first.message
          end
        end
      end
    end
  end
end
