require_relative "test_helper"

class AppenderTest < Minitest::Test
  describe SemanticLogger::Appender do
    # #build is a private class method reached publicly via SemanticLogger.add_appender.
    def build(**args, &block)
      SemanticLogger::Appender.send(:build, **args, &block)
    end

    describe ".build" do
      describe "with :appender" do
        it "raises when not a Symbol or Subscriber" do
          error = assert_raises ArgumentError do
            build(appender: "not valid")
          end
          assert_includes error.message, "Parameter :appender"
          assert_includes error.message, "not: \"not valid\""
        end

        it "formats with the block, for an appender named by a Symbol" do
          formatter = ->(log, _logger) { log.message }
          appender  = build(appender: :udp, server: "localhost:10514", metrics: false, &formatter)

          assert_same formatter, appender.formatter
        ensure
          appender&.close
        end
      end

      describe "with :metric" do
        it "builds a metric subscriber from a Symbol" do
          appender = build(metric: :statsd)

          assert_kind_of SemanticLogger::Metric::Statsd, appender
        end

        it "returns the supplied metric Subscriber instance" do
          metric   = SemanticLogger::Metric::Statsd.new
          appender = build(metric: metric)

          assert_same metric, appender
        end

        it "formats with the block, for a metric subscriber named by a Symbol" do
          SemanticLogger::Metric.const_set(:BlockFormatted, Class.new(SemanticLogger::Subscriber))
          formatter = ->(log, _logger) { log.metric }
          appender  = build(metric: :block_formatted, &formatter)

          assert_same formatter, appender.formatter
        ensure
          SemanticLogger::Metric.send(:remove_const, :BlockFormatted)
        end

        it "raises when not a Symbol or Subscriber" do
          error = assert_raises ArgumentError do
            build(metric: "not valid")
          end
          assert_includes error.message, "Parameter :metric"
          assert_includes error.message, "not: \"not valid\""
        end
      end

      it "raises when no destination option is supplied" do
        error = assert_raises ArgumentError do
          build(level: :info)
        end
        assert_includes error.message, ":io, :file_name, :appender, :metric, or :logger"
      end

      describe "with more than one destination" do
        let(:io) { StringIO.new }
        let(:file_name) { File.join(Dir.tmpdir, "semantic_logger_appender_test_#{Process.pid}.log") }

        after do
          FileUtils.rm_f(file_name)
        end

        it "adds the first destination, and warns naming it and the one it ignores, at the line that supplied them" do
          subscriber = InMemoryAppender.new
          line       = __LINE__ + 3
          warning    = /appender_test\.rb:#{line}: warning: SemanticLogger: .* it uses io: and ignores appender:,/
          appender   = assert_deprecated(warning) do
            SemanticLogger::Appender.factory(appender: subscriber, io: io)
          end

          assert_instance_of SemanticLogger::Appender::IO, appender
        end

        it "says that v6 raises ArgumentError for them, and to add each destination on its own" do
          message = "add_appender adds one destination, so it uses file_name: and ignores io:, and v6 raises " \
                    "ArgumentError when given more than one. Call add_appender once for each destination."
          appender = assert_deprecated(/SemanticLogger: #{Regexp.escape(message)}$/) do
            build(io: io, file_name: file_name)
          end

          assert_instance_of SemanticLogger::Appender::File, appender
        ensure
          appender&.close
        end

        it "takes file_name:, io:, logger:, appender:, and metric: in that order, naming each one it ignores" do
          wrapped = Logger.new(io)
          warning = /it uses io: and ignores logger:, appender:, and metric:,/
          appender = assert_deprecated(warning) do
            build(metric: :statsd, appender: InMemoryAppender.new, logger: wrapped, io: io)
          end

          assert_instance_of SemanticLogger::Appender::IO, appender

          appender = assert_deprecated(/it uses logger: and ignores appender: and metric:,/) do
            build(metric: InMemoryMetricsAppender.new, appender: :bugsnag, logger: wrapped)
          end

          assert_same wrapped, appender.wrapped_logger

          appender = assert_deprecated(/it uses appender: and ignores metric:,/) do
            build(metric: :statsd, appender: :bugsnag)
          end

          assert_instance_of SemanticLogger::Appender::Bugsnag, appender
        end

        it "does not warn for a destination that is nil or false, which is not given" do
          appender = refute_deprecated { build(file_name: nil, io: io, logger: false, appender: nil, metric: nil) }

          assert_instance_of SemanticLogger::Appender::IO, appender
        end

        it "hands the other options and the block to the destination that it adds" do
          formatter = ->(log, _logger) { log.message }
          appender  = assert_deprecated(/it uses io: and ignores appender:,/) do
            build(appender: InMemoryAppender.new, io: io, level: :warn, &formatter)
          end

          assert_equal :warn, appender.level
          assert_same formatter, appender.formatter
        end
      end

      [[:appender, InMemoryAppender], [:metric, InMemoryMetricsAppender]].each do |option, subscriber_class|
        describe "with a Subscriber instance as #{option}:" do
          let(:subscriber) { subscriber_class.new }
          let(:ignored) { "add_appender ignores" }
          let(:instance) { Regexp.escape("when #{option}: is a Subscriber instance (#{subscriber_class})") }

          it "returns the instance, without a warning" do
            result = refute_deprecated { build(option => subscriber) }

            assert_same subscriber, result
          end

          it "warns that the block is ignored, at the line that supplied it, and returns the instance unchanged" do
            formatter = subscriber.formatter
            line      = __LINE__ + 3
            warning   = /appender_test\.rb:#{line}: warning: SemanticLogger: #{ignored} the formatter block /
            result    = assert_deprecated(warning) do
              SemanticLogger::Appender.factory(option => subscriber) { |log, _logger| log.message }
            end

            assert_same subscriber, result
            assert_same formatter, subscriber.formatter
          end

          it "says that v6 raises ArgumentError for the block, to set it on the instance, and what applies to it" do
            advice = "Set it on the instance itself; only async:, batch:, and the queue options of add_appender " \
                     "apply to an instance."
            assert_deprecated(/#{instance}, and v6 raises ArgumentError for it\. #{Regexp.escape(advice)}$/) do
              build(option => subscriber) { |log, _logger| log.message }
            end
          end

          it "does not warn for the options that are nil, which set nothing" do
            result = refute_deprecated { build(option => subscriber, level: nil, formatter: nil, filter: nil) }

            assert_same subscriber, result
          end

          it "names only the options that are not nil" do
            assert_deprecated(/#{ignored} formatter: #{instance}, .* for it\. Set it /) do
              build(option => subscriber, level: nil, formatter: :json)
            end
          end

          it "names a misspelled option of add_appender, and the options that apply to an instance" do
            assert_deprecated(/#{ignored} max_queue: #{instance}, .*; only async:, batch:, and the queue options /) do
              SemanticLogger::Appender.factory(option => subscriber, max_queue: 5)
            end
          end

          it "warns naming each option that is ignored, and returns the instance unchanged" do
            level     = subscriber.level
            formatter = subscriber.formatter
            result    = assert_deprecated(
              /#{ignored} level:, formatter:, filter:, application:, and metrics: #{instance}, .* for them\. Set them /
            ) do
              build(option => subscriber, level: :fatal, formatter: :json, filter: /Other/, application: "Other",
                    metrics: true)
            end

            assert_same subscriber, result
            assert_equal level, subscriber.level
            assert_same formatter, subscriber.formatter
            assert_nil subscriber.filter
            assert_equal SemanticLogger.application, subscriber.application
            refute_predicate subscriber, :metrics?
          end

          it "warns naming the block and the option that are ignored" do
            assert_deprecated(/#{ignored} the formatter block and level: #{instance}, .* for them\. Set them /) do
              build(option => subscriber, level: :fatal) { |log, _logger| log.message }
            end
          end

          it "applies the options of add_appender to the instance, without a warning" do
            added = refute_deprecated do
              SemanticLogger::Appender.factory(option => subscriber, async: true, max_queue_size: 5,
                                               lag_check_interval: 10, lag_threshold_s: 1, non_blocking: true,
                                               dropped_message_report_seconds: 1, async_max_retries: 1)
            end

            assert_instance_of SemanticLogger::Appender::Async, added
            assert_same subscriber, added.appender
            assert_equal 5, added.max_queue_size
          ensure
            added&.close
          end

          it "applies the batch options of add_appender to the instance, without a warning" do
            batcher = InMemoryBatchAppender.new
            added   = refute_deprecated do
              SemanticLogger::Appender.factory(option => batcher, batch: true, batch_size: 2, batch_seconds: 1)
            end

            assert_predicate added, :batch?
            assert_same batcher, added.appender
            assert_equal 2, added.processor.batch_size
          ensure
            added&.close
          end
        end
      end
    end

    describe ".factory" do
      describe "batching an appender whose formatter cannot format a batch" do
        let(:block) { ->(log, _logger) { log.message } }
        let(:refused) { "add_appender cannot batch %s, since its formatter cannot format a batch" }

        # Creates the appender without connecting to its server.
        def factory(**, &)
          Net::HTTP.stub_any_instance(:start, true) { SemanticLogger::Appender.factory(**, &) }
        end

        {
          SemanticLogger::Appender::Http   => {appender: :http, url: "http://localhost:8088/path"},
          SemanticLogger::Appender::Loki   => {appender: :loki, url: "http://localhost:3100"},
          SemanticLogger::Metric::Signalfx => {metric: :signalfx, token: "TEST"}
        }.each_pair do |appender_class, options|
          it "raises ArgumentError for #{options.values.first.inspect} with batch: true and a formatter block" do
            error = assert_raises(ArgumentError) { factory(**options, batch: true, &block) }

            assert_includes error.message, format(refused, appender_class)
          end
        end

        it "says to give it a formatter that implements #batch, or to add it with batch: false" do
          error = assert_raises(ArgumentError) do
            factory(appender: :http, url: "http://localhost:8088/path", batch: true, formatter: :default)
          end

          assert_equal "#{format(refused, SemanticLogger::Appender::Http)}, as a formatter block or Proc cannot. " \
                       "Give it a formatter that implements #batch(logs, logger), or add it with batch: false.",
                       error.message
        end

        it "raises ArgumentError for an appender instance given with batch: true" do
          appender = factory(appender: :http, url: "http://localhost:8088/path", &block)

          assert_raises(ArgumentError) { factory(appender: appender, batch: true) }
        end

        it "raises ArgumentError for an appender batched by default" do
          batched = Class.new(SemanticLogger::Appender::Http) do
            def batch_by_default? = true
          end

          appender = Net::HTTP.stub_any_instance(:start, true) { batched.new(url: "http://localhost:8088/path", &block) }

          assert_raises(ArgumentError) { factory(appender: appender) }
        end

        it "batches the appender with a formatter that can format a batch" do
          added = factory(appender: :http, url: "http://localhost:8088/path", batch: true)

          assert_predicate added, :batch?
        ensure
          added&.close
        end

        it "adds the appender with a formatter block, when not batched" do
          added = factory(appender: :http, url: "http://localhost:8088/path", batch: false, &block)

          assert_instance_of SemanticLogger::Appender::Http, added
          assert_same block, added.formatter
        end

        it "batches an appender whose #batch formats each log message, with a formatter block" do
          appender = Class.new(SemanticLogger::Subscriber) do
            def written
              @written ||= []
            end

            def batch(logs)
              logs.each { |log| written << format_log(log) }
            end
          end.new(&block)
          added    = factory(appender: appender, batch: true)
          log      = SemanticLogger::Log.new("Test", :info).tap { |entry| entry.message = "hello" }
          added.log(log)
          added.flush

          assert_equal ["hello"], appender.written
        ensure
          added&.close
        end
      end

      describe "with async: true" do
        # A custom appender may define its own #logger, as the appender contract allows. The worker
        # thread reports to it, starting with a trace, so one that cannot take that must not stop it.
        it "writes every entry of an appender whose own #logger has no #trace, and logging does not block" do
          appender = Class.new(SemanticLogger::Subscriber) do
            def written
              @written ||= []
            end

            def log(log)
              written << log.message
              true
            end

            def logger
              @logger ||= ::Logger.new(File::NULL)
            end
          end.new
          proxy   = SemanticLogger::Appender.factory(appender: appender, async: true, max_queue_size: 2)
          entries = Array.new(5) do |i|
            SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "entry #{i}" }
          end
          logging = Thread.new { entries.each { |log| proxy.log(log) } }

          assert logging.join(5), "logging blocked once the queue was full"
          assert proxy.flush, "the worker thread should be running to flush"
          assert_equal entries.map(&:message), appender.written
        ensure
          logging&.kill
          proxy&.close
        end
      end
    end
  end
end
