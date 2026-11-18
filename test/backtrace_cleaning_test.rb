require_relative "test_helper"

class BacktraceCleaningTest < Minitest::Test
  include BacktraceCleanerFixtures

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

    describe ".validate!" do
      it "returns a cleaner" do
        cleaner = AppCleaner.new

        assert_same cleaner, SemanticLogger::BacktraceCleaning.validate!(cleaner)
      end

      it "rejects other values" do
        [nil, true, "app", :clean].each do |value|
          error = assert_raises(ArgumentError) { SemanticLogger::BacktraceCleaning.validate!(value) }

          assert_includes error.message, "Expected a backtrace cleaner that responds to #clean or #call"
        end
      end
    end

    describe ".clean" do
      it "returns the lines from #clean" do
        assert_equal [CLEANED_FRAME], SemanticLogger::BacktraceCleaning.clean(backtrace, AppCleaner.new)
      end

      it "returns the lines from #call" do
        assert_equal [APP_FRAME], SemanticLogger::BacktraceCleaning.clean(backtrace, ->(lines) { lines.grep(/app/) })
      end

      it "prefers #clean when the cleaner also responds to #call" do
        cleaner = AppCleaner.new
        def cleaner.call(_lines) = ["from call"]

        assert_equal [CLEANED_FRAME], SemanticLogger::BacktraceCleaning.clean(backtrace, cleaner)
      end

      it "returns a frozen Array of frozen lines" do
        cleaned = SemanticLogger::BacktraceCleaning.clean(backtrace, AppCleaner.new)

        assert_predicate cleaned, :frozen?
        assert cleaned.all?(&:frozen?)
      end

      it "does not freeze the lines the cleaner returns" do
        line = +"app/a.rb:1"
        SemanticLogger::BacktraceCleaning.clean(backtrace, ->(_lines) { [line] })

        refute_predicate line, :frozen?
      end

      it "does not freeze the supplied lines, even of a String subclass" do
        line_class = Class.new(String)
        lines      = [line_class.new(APP_FRAME), line_class.new(GEM_FRAME)]
        SemanticLogger::BacktraceCleaning.clean(lines, ->(cleaned) { cleaned })
        SemanticLogger::BacktraceCleaning.clean(lines, ->(_lines) {})

        refute lines.any?(&:frozen?)
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

      it "returns a frozen copy of the supplied backtrace when the cleaner leaves out every line" do
        gems_only = [+GEM_FRAME, +GEM_FRAME]
        cleaned   = SemanticLogger::BacktraceCleaning.clean(gems_only, AppCleaner.new)

        assert_equal gems_only, cleaned
        assert_predicate cleaned, :frozen?
        assert cleaned.all?(&:frozen?)
        refute_predicate gems_only, :frozen?
        refute gems_only.any?(&:frozen?)
      end

      it "returns the supplied backtrace when the cleaner does not return an Array" do
        assert_equal backtrace, SemanticLogger::BacktraceCleaning.clean(backtrace, ->(_lines) { "app" })
        assert_equal backtrace, SemanticLogger::BacktraceCleaning.clean(backtrace, ->(_lines) {})
      end

      describe "when the cleaner raises" do
        let(:io) { StringIO.new }
        let(:cleaner) { ->(_lines) { raise "broken" } }
        let(:clean_from) { cleaner }

        # The internal logger writes text, as by default, so that it would ask the cleaner to clean
        # the backtrace of any exception it is given.
        def internal_processor
          SemanticLogger::SyncProcessor.new(SemanticLogger::Appenders.new(SemanticLogger::Appender::IO.new(io)))
        end

        def clean_reporting_to_io(backtrace)
          SemanticLogger::Logger.stub(:processor, internal_processor) do
            SemanticLogger::BacktraceCleaning.clean(backtrace, clean_from)
          end
        end

        before { SemanticLogger.backtrace_cleaner = cleaner }
        after { SemanticLogger.backtrace_cleaner = nil }

        it "returns the supplied backtrace" do
          assert_equal backtrace, clean_reporting_to_io(backtrace)
        end

        it "reports the error, and where it was raised, to the internal logger" do
          clean_reporting_to_io(backtrace)

          assert_match(/W .*Backtrace cleaner raised RuntimeError: broken \(.*backtrace_cleaning_test\.rb:\d+/,
                       io.string)
          assert_includes io.string, "so the full backtrace is logged"
        end

        it "names an error class without a name" do
          error_class = Class.new(StandardError)
          cleaner     = ->(_lines) { raise error_class, "broken" }
          SemanticLogger::Logger.stub(:processor, internal_processor) do
            SemanticLogger::BacktraceCleaning.clean(backtrace, cleaner)
          end

          assert_includes io.string, "raised #{error_class.inspect}: broken"
        end

        it "reports the message the error was raised with when its #message raises" do
          cleaner = ->(_lines) { raise ExceptionFixtures::AbstractMessageError, "broken" }
          cleaned = SemanticLogger::Logger.stub(:processor, internal_processor) do
            SemanticLogger::BacktraceCleaning.clean(backtrace, cleaner)
          end

          assert_equal backtrace, cleaned
          assert_includes io.string, "Backtrace cleaner raised ExceptionFixtures::AbstractMessageError: broken"
        end

        describe "for a line that cannot be written as text" do
          let(:clean_from) do
            line = Object.new
            def line.to_s = raise("no text")
            ->(_lines) { [line] }
          end

          it "returns the supplied backtrace, and reports the error" do
            assert_equal backtrace, clean_reporting_to_io(backtrace)
            assert_includes io.string, "Backtrace cleaner raised RuntimeError: no text"
          end
        end

        describe "for an object that is not a cleaner, such as the formatter option true" do
          let(:clean_from) { true }

          it "returns the supplied backtrace, and reports the error" do
            assert_equal backtrace, clean_reporting_to_io(backtrace)
            assert_includes io.string, "Backtrace cleaner raised NoMethodError"
          end
        end
      end

      it "does not call the cleaner without a backtrace" do
        cleaner = ->(_lines) { raise "should not be called" }

        assert_nil SemanticLogger::BacktraceCleaning.clean(nil, cleaner)
        assert_equal [], SemanticLogger::BacktraceCleaning.clean([], cleaner)
      end
    end
  end
end
