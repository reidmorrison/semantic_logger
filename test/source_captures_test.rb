require_relative "test_helper"
require_relative "signal_trap_helper"

class SourceCapturesTest < Minitest::Test
  # An appender whose source captures are those given, in place of its formatter's.
  class CapturingAppender < SemanticLogger::Subscriber
    attr_reader :logged

    def initialize(captures = [], **args)
      @captures = captures
      @logged   = []
      super(**args)
    end

    def source_captures = @captures

    def log(log)
      @logged << log
      true
    end
  end

  module Helpers
    def entry(level = :info)
      SemanticLogger::Log.new("SourceCapturesTest", level)
    end

    # Returns a capture that adds each entry that it is called with to calls.
    def recording_capture(calls)
      ->(log) { calls << log }
    end
  end

  describe SemanticLogger::SourceCaptures do
    include Helpers

    let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }
    # Reports to the logger, as the appenders report to their internal logger.
    let(:reporter) { Struct.new(:logger).new(logger) }

    def plan(*appenders)
      SemanticLogger::SourceCaptures.new(appenders, SemanticLogger::SourceCaptures.generation)
    end

    it "runs a capture that several appenders return once per entry" do
      calls   = []
      capture = recording_capture(calls)
      plan(CapturingAppender.new([capture]), CapturingAppender.new([capture])).call(entry, reporter)

      assert_equal 1, calls.size
    end

    it "runs a capture only for an entry that an appender using it writes at its level" do
      calls   = []
      capture = recording_capture(calls)
      captures = plan(CapturingAppender.new([capture], level: :error), CapturingAppender.new(level: :trace))
      captures.call(entry(:info), reporter)

      assert_empty calls
      captures.call(entry(:error), reporter)

      assert_equal 1, calls.size
    end

    it "runs a capture for an entry that any of the appenders using it writes" do
      calls   = []
      capture = recording_capture(calls)
      plan(CapturingAppender.new([capture], level: :error), CapturingAppender.new([capture], level: :debug)).
        call(entry(:info), logger)

      assert_equal 1, calls.size
    end

    it "asks the appender wrapped by an asynchronous one for its captures and level" do
      calls    = []
      appender = SemanticLogger::Appender::Async.new(appender: CapturingAppender.new([recording_capture(calls)],
                                                                                     level: :warn))
      captures = plan(appender)
      captures.call(entry(:info), reporter)
      captures.call(entry(:warn), reporter)

      assert_equal 1, calls.size
    ensure
      appender&.close
    end

    it "reports a capture that raises, and still runs the others" do
      calls   = []
      raising = ->(_log) { raise "capture failed" }
      plan(CapturingAppender.new([raising, recording_capture(calls)])).call(entry, reporter)

      assert_equal 1, calls.size
      assert_equal "Exception calling a source capture", logger.events.first.message
      assert_equal "capture failed", logger.events.first.exception.message
    end

    it "leaves out an appender that does not answer source captures" do
      assert_empty plan(Object.new).captures
    end

    it "is current until a change is counted" do
      captures = plan

      assert_predicate captures, :current?
      SemanticLogger::SourceCaptures.changed

      refute_predicate captures, :current?
    end
  end

  describe SemanticLogger::Appenders do
    include Helpers

    let(:appenders) { SemanticLogger::Appenders.new }

    it "runs the captures of the appenders it holds, and no longer those of one it removed" do
      calls    = []
      appender = CapturingAppender.new([recording_capture(calls)])
      appenders << appender
      appenders.capture(entry)

      assert_equal 1, calls.size
      appenders.delete(appender)
      appenders.capture(entry)

      assert_equal 1, calls.size
    end

    it "runs none once cleared" do
      calls = []
      appenders << CapturingAppender.new([recording_capture(calls)])
      appenders.clear
      appenders.capture(entry)

      assert_empty calls
    end

    it "runs those of the formatter that an appender it holds is given afterwards" do
      calls     = []
      capture   = recording_capture(calls)
      formatter = SemanticLogger::Formatters::Default.new
      formatter.define_singleton_method(:source_captures) { [capture] }
      appender = InMemoryAppender.new(formatter: :default)
      appenders << appender
      appenders.capture(entry)

      assert_empty calls
      appender.formatter = formatter
      appenders.capture(entry)

      assert_equal 1, calls.size
    end

    it "builds the captures of an appender added in a signal trap" do
      extend SignalTrapHelper

      calls    = []
      appender = CapturingAppender.new([recording_capture(calls)])
      added    = in_signal_trap { (appenders << appender).size }

      assert_equal 1, added
      appenders.capture(entry)

      assert_equal 1, calls.size
    end
  end

  describe "a log call" do
    include Helpers

    let(:appenders) { SemanticLogger::Appenders.new }
    let(:processor) { SemanticLogger::SyncProcessor.new(appenders) }

    after { SemanticLogger::Logger.clear_subscribers }

    it "runs the captures on the thread that logs, after the on_log subscribers" do
      order    = []
      threads  = []
      capture  = lambda do |_log|
        order << :capture
        threads << Thread.current
      end
      appender = CapturingAppender.new([capture])
      appenders << appender
      SemanticLogger.on_log { |_log| order << :on_log }
      SemanticLogger::Logger.stub(:processor, processor) { SemanticLogger["Test"].info("hello") }

      assert_equal %i[on_log capture], order
      assert_equal [Thread.current], threads
      assert_equal 1, appender.logged.size
    end

    it "runs them on the thread that logs with the asynchronous processor too" do
      threads   = []
      processor = SemanticLogger::Processor.new
      processor.appenders << CapturingAppender.new([->(_log) { threads << Thread.current }])
      processor.log(entry)
      processor.flush

      assert_equal [Thread.current], threads
    ensure
      processor&.close
    end

    it "does not run them for an entry whose captures ran where it was logged, such as in another Ractor" do
      calls = []
      appenders << CapturingAppender.new([recording_capture(calls)])
      processor.log_captured(entry)

      assert_empty calls
    end

    it "does not run them for the reports of the internal logger" do
      calls = []
      SemanticLogger.add_appender(appender: CapturingAppender.new([recording_capture(calls)]))
      SemanticLogger::Processor.logger.stub(:log, true) { SemanticLogger.internal_logger.error("report") }

      assert_empty calls
    ensure
      SemanticLogger.appenders.select { |appender| appender.is_a?(CapturingAppender) }.
        each { |appender| SemanticLogger.remove_appender(appender) }
    end
  end
end
