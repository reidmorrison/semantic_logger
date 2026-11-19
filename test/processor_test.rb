require_relative "test_helper"

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
