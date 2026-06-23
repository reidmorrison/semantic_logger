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
          thread = p.instance_variable_get(:@thread)
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

      describe "#start" do
        it "returns false when the worker thread is already active" do
          assert_predicate processor, :active?
          refute processor.start
        end

        it "returns true and starts the thread when not active" do
          thread = processor.instance_variable_get(:@thread)
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
