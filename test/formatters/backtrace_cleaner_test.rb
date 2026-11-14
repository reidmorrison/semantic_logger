require_relative "../test_helper"

# The NewRelicLogs formatter requires newrelic_rpm.
add_mocks_to_load_path

require "opentelemetry-logs-sdk"
require "semantic_logger/formatters/open_telemetry"

module SemanticLogger
  module Formatters
    class BacktraceCleanerTest < Minitest::Test
      # Has the interface of ActiveSupport::BacktraceCleaner: keeps the application's own frames,
      # relative to its root.
      class AppCleaner
        def clean(backtrace)
          backtrace.select { |line| line.start_with?("/app/") }.map { |line| line.delete_prefix("/app/") }
        end
      end

      MOCK_LOGGER = Struct.new(:host, :application, :environment, :name)

      APP_FRAME     = "/app/models/order.rb:12:in 'Order#ship'".freeze
      CLEANED_FRAME = "models/order.rb:12:in 'Order#ship'".freeze
      GEM_FRAME     = "/gems/rack-3.1.0/lib/rack/runtime.rb:24:in 'Rack::Runtime#call'".freeze

      # Only in a backtrace line: the file name and line number fields, taken from the exception's
      # first frame when the entry has no backtrace of its own, do not include the method.
      GEM_METHOD = "Rack::Runtime#call".freeze

      # A pattern that writes the backtrace, which the default pattern leaves out.
      class BacktracePattern < Pattern
        def initialize(**args)
          # rubocop:disable Style/FormatStringToken -- the Pattern formatter's syntax, not a format string
          super(pattern: "%{message} %{backtrace}", **args)
          # rubocop:enable Style/FormatStringToken
        end
      end

      # Formatters that clean backtraces with the application's cleaner unless told otherwise.
      CLEANING = [Default, Color, BacktracePattern, Syslog, Json, Fluentd].freeze

      # Formatters that write backtraces in full unless told otherwise.
      NOT_CLEANING = [Raw, Ecs, Logfmt, NewRelicLogs, SyslogCee, Loki, OpenTelemetry].freeze

      describe "backtrace_cleaner" do
        let(:logger) { MOCK_LOGGER.new("host", "app", "test", "BacktraceCleanerTest") }

        let(:exception) do
          exception = RuntimeError.new("Oh no")
          exception.set_backtrace([GEM_FRAME, APP_FRAME, GEM_FRAME])
          exception
        end

        let(:log) do
          log           = SemanticLogger::Log.new("BacktraceCleanerTest", :error)
          log.message   = "Failed"
          log.exception = exception
          log
        end

        # The formatted output, as text that holds every backtrace line.
        def output(formatter)
          formatter.call(log, logger).to_s
        end

        def assert_cleaned(formatter)
          text = output(formatter)

          assert_includes text, CLEANED_FRAME
          refute_includes text, GEM_METHOD
          refute_includes text, APP_FRAME
        end

        def assert_full(formatter)
          text = output(formatter)

          assert_includes text, APP_FRAME
          assert_includes text, GEM_METHOD
        end

        before { SemanticLogger.backtrace_cleaner = AppCleaner.new }
        after { SemanticLogger.backtrace_cleaner = nil }

        describe "by default" do
          CLEANING.each do |formatter_class|
            it "cleans backtraces with the application's cleaner in #{formatter_class.name}" do
              assert_cleaned formatter_class.new
            end
          end

          NOT_CLEANING.each do |formatter_class|
            it "writes backtraces in full in #{formatter_class.name}" do
              assert_full formatter_class.new
            end
          end

          it "writes backtraces in full when the application has no cleaner" do
            SemanticLogger.backtrace_cleaner = nil

            assert_full Default.new
            assert_full Json.new
          end

          it "uses the application's cleaner set after the formatter was built" do
            SemanticLogger.backtrace_cleaner = nil
            formatter                        = Json.new
            SemanticLogger.backtrace_cleaner = AppCleaner.new

            assert_cleaned formatter
          end
        end

        describe "when false" do
          it "writes backtraces in full in a formatter that cleans them by default" do
            assert_full Default.new(backtrace_cleaner: false)
            assert_full Formatters.factory(json: {backtrace_cleaner: false})
          end
        end

        describe "when true" do
          NOT_CLEANING.each do |formatter_class|
            it "cleans backtraces with the application's cleaner in #{formatter_class.name}" do
              assert_cleaned formatter_class.new(backtrace_cleaner: true)
            end
          end
        end

        describe "with a cleaner of the formatter's own" do
          it "uses it in place of the application's cleaner" do
            SemanticLogger.backtrace_cleaner = nil
            formatter                        = Formatters.factory(raw: {backtrace_cleaner: AppCleaner.new})

            assert_equal [CLEANED_FRAME], formatter.call(log, logger)[:exception][:stack_trace]
          end

          it "accepts a Proc" do
            formatter = Default.new(backtrace_cleaner: ->(lines) { lines.grep(/rack/) })

            refute_includes output(formatter), APP_FRAME
          end

          it "can be assigned after the formatter was built" do
            formatter                   = Raw.new
            formatter.backtrace_cleaner = AppCleaner.new

            assert_cleaned formatter
          end
        end

        it "rejects a value that cannot clean a backtrace" do
          assert_raises(ArgumentError) { Default.new(backtrace_cleaner: "rails") }
          assert_raises(ArgumentError) { Json.new.backtrace_cleaner = :clean }
        end

        it "cleans the backtrace of each exception that caused the logged one" do
          begin
            begin
              raise ArgumentError, "inner"
            rescue ArgumentError => e
              e.set_backtrace([GEM_FRAME, "/app/models/line_item.rb:3:in 'LineItem#save'"])
              raise "outer"
            end
          rescue RuntimeError => e
            e.set_backtrace([GEM_FRAME, APP_FRAME])
            log.exception = e
          end

          assert_equal "-- Exception: RuntimeError: outer\n#{CLEANED_FRAME}\n" \
                       "Cause: ArgumentError: inner\nmodels/line_item.rb:3:in 'LineItem#save'",
                       Default.new.tap { |formatter| formatter.call(log, logger) }.exception

          cause = Raw.new(backtrace_cleaner: true).call(log, logger)[:exception][:cause]

          assert_equal ["models/line_item.rb:3:in 'LineItem#save'"], cause[:stack_trace]
        end

        it "writes the backtrace in full when the cleaner leaves out every line" do
          exception.set_backtrace([GEM_FRAME])

          assert_includes output(Default.new), GEM_FRAME
        end

        it "escapes control characters in the cleaned lines" do
          formatter = Default.new(escape_control_chars: true, backtrace_cleaner: ->(_lines) { ["app/a.rb:1\n forged"] })

          assert_includes output(formatter), "app/a.rb:1\\n forged"
        end

        it "leaves the exception's backtrace unchanged" do
          output(Default.new)

          assert_equal [GEM_FRAME, APP_FRAME, GEM_FRAME], exception.backtrace
        end
      end
    end
  end
end
