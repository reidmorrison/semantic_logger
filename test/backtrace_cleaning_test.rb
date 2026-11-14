require_relative "test_helper"

class BacktraceCleaningTest < Minitest::Test
  # Has the interface of ActiveSupport::BacktraceCleaner: keeps the application's own frames,
  # relative to its root.
  class AppCleaner
    def clean(backtrace)
      backtrace.select { |line| line.start_with?("/app/") }.map { |line| line.delete_prefix("/app/") }
    end
  end

  APP_FRAME = "/app/models/order.rb:12:in 'Order#ship'".freeze
  GEM_FRAME = "/gems/rack-3.1.0/lib/rack/runtime.rb:24:in 'Rack::Runtime#call'".freeze

  describe SemanticLogger::BacktraceCleaning do
    let(:backtrace) { [GEM_FRAME, APP_FRAME, GEM_FRAME] }

    describe ".cleaner?" do
      it "accepts an object that responds to #clean" do
        assert SemanticLogger::BacktraceCleaning.cleaner?(AppCleaner.new)
      end

      it "accepts a Proc" do
        assert SemanticLogger::BacktraceCleaning.cleaner?(->(lines) { lines })
      end

      it "rejects other values" do
        [nil, true, "app", :clean].each do |value|
          refute SemanticLogger::BacktraceCleaning.cleaner?(value), value.inspect
        end
      end
    end

    describe ".clean" do
      it "returns the lines from #clean" do
        assert_equal ["models/order.rb:12:in 'Order#ship'"],
                     SemanticLogger::BacktraceCleaning.clean(backtrace, AppCleaner.new)
      end

      it "returns the lines from #call" do
        assert_equal [APP_FRAME], SemanticLogger::BacktraceCleaning.clean(backtrace, ->(lines) { lines.grep(/app/) })
      end

      it "prefers #clean when the cleaner also responds to #call" do
        cleaner = AppCleaner.new
        def cleaner.call(_lines) = ["from call"]

        assert_equal ["models/order.rb:12:in 'Order#ship'"], SemanticLogger::BacktraceCleaning.clean(backtrace, cleaner)
      end

      it "returns frozen lines" do
        assert_predicate SemanticLogger::BacktraceCleaning.clean(backtrace, AppCleaner.new), :frozen?
      end

      it "writes a Thread::Backtrace::Location as a String" do
        cleaned = SemanticLogger::BacktraceCleaning.clean(backtrace, ->(_lines) { caller_locations(0, 1) })

        assert_equal [String], cleaned.map(&:class)
        assert_includes cleaned.first, "backtrace_cleaning_test.rb"
      end

      it "leaves the supplied backtrace unchanged when the cleaner changes the lines it is given" do
        original = backtrace.dup
        cleaner  = ->(lines) { lines.reject! { |line| line == GEM_FRAME } }
        cleaned  = SemanticLogger::BacktraceCleaning.clean(backtrace, cleaner)

        assert_equal [APP_FRAME], cleaned
        assert_equal original, backtrace
      end

      it "returns the supplied backtrace when the cleaner leaves out every line" do
        gems_only = [GEM_FRAME, GEM_FRAME]

        assert_same gems_only, SemanticLogger::BacktraceCleaning.clean(gems_only, AppCleaner.new)
      end

      it "returns the supplied backtrace when the cleaner does not return an Array" do
        assert_same backtrace, SemanticLogger::BacktraceCleaning.clean(backtrace, ->(_lines) { "app" })
        assert_same backtrace, SemanticLogger::BacktraceCleaning.clean(backtrace, ->(_lines) {})
      end

      it "returns the supplied backtrace when the cleaner raises" do
        assert_same backtrace, SemanticLogger::BacktraceCleaning.clean(backtrace, ->(_lines) { raise "broken" })
      end

      it "does not call the cleaner without a backtrace" do
        cleaner = ->(_lines) { raise "should not be called" }

        assert_nil SemanticLogger::BacktraceCleaning.clean(nil, cleaner)
        assert_equal [], SemanticLogger::BacktraceCleaning.clean([], cleaner)
      end
    end
  end
end
