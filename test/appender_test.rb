require_relative "test_helper"

class AppenderTest < Minitest::Test
  describe SemanticLogger::Appender do
    # #build is a private class method reached publicly via SemanticLogger.add_appender.
    def build(**, &)
      built(**, &).first
    end

    # Returns [appender, created] as #build returns them.
    def built(**, &)
      SemanticLogger::Appender.send(:build, **, &)
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

      describe "says whether it created the appender" do
        it "created it for file_name:, or for a Symbol given as appender: or metric:" do
          file_name = File.join(Dir.tmpdir, "semantic_logger_appender_test_#{Process.pid}.log")

          assert built(file_name: file_name).last
          assert built(appender: :bugsnag).last
          assert built(metric: :statsd).last
        ensure
          FileUtils.rm_f(file_name)
        end

        it "did not for a Subscriber instance given as appender: or metric:, nor for io: or logger:, " \
           "which the caller holds" do
          io = StringIO.new

          refute built(appender: InMemoryAppender.new).last
          refute built(metric: InMemoryMetricsAppender.new).last
          refute built(io: io).last
          refute built(logger: Logger.new(io)).last
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

        it "says that it created the appender for file_name:, which it adds rather than the logger: it ignores" do
          appender, created = assert_deprecated(/it uses file_name: and ignores logger:,/) do
            built(file_name: file_name, logger: Logger.new(io))
          end

          assert_instance_of SemanticLogger::Appender::File, appender
          assert created
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

    describe ".internal_logger" do
      it "returns an appender as it is" do
        appender = SemanticLogger::Appender::IO.new(StringIO.new)

        assert_same appender, SemanticLogger::Appender.internal_logger(appender)
      end

      it "returns nil, which restores the default" do
        assert_nil SemanticLogger::Appender.internal_logger(nil)
      end

      it "returns nil for false" do
        assert_nil SemanticLogger::Appender.internal_logger(false)
      end

      it "raises for a SemanticLogger::Logger, which would log its reports back to the failing appender" do
        error = assert_raises(ArgumentError) { SemanticLogger::Appender.internal_logger(SemanticLogger["Internal"]) }

        assert_includes error.message, "A SemanticLogger::Logger cannot be the internal logger"
      end

      it "returns as it is a logger that logs at trace and takes an exception" do
        custom = Class.new do
          attr_accessor :name, :reports

          SemanticLogger::LEVELS.each do |level|
            define_method(level) { |message, exception = nil| (@reports ||= []) << [level, message, exception] }
          end
        end.new

        assert_same custom, SemanticLogger::Appender.internal_logger(custom)
      end

      describe "with a Ruby Logger" do
        let(:output) { StringIO.new }
        let(:ruby_logger) { ::Logger.new(output) }
        let(:internal) { SemanticLogger::Appender.internal_logger(ruby_logger) }

        it "wraps it in an appender that writes to it" do
          assert_kind_of SemanticLogger::Appender::Wrapper, internal
          assert_same ruby_logger, internal.wrapped_logger
        end

        it "takes a name, and an exception after the message" do
          internal.name = "SemanticLogger::Appenders"
          internal.error("Failed to log to appender: File", IOError.new("disk full"))

          assert_includes output.string, "ERROR -- : "
          assert_includes output.string,
                          "SemanticLogger::Appenders -- Failed to log to appender: File " \
                          "-- Exception: IOError: disk full"
        end

        it "writes the reports at its own level and above" do
          ruby_logger.level = :info
          internal.debug("Not written")
          internal.info("Written")

          refute_includes output.string, "Not written"
          assert_includes output.string, "INFO -- : "
        end

        it "leaves out the trace reports, which are below its lowest level" do
          internal.trace("Flushing appender: File")
          internal.debug("Opened file")

          refute_includes output.string, "Flushing appender"
          assert_includes output.string, "DEBUG -- : "
        end
      end

      it "raises for a logger without the logging methods" do
        error = assert_raises(ArgumentError) { SemanticLogger::Appender.internal_logger(Object.new) }

        assert_includes error.message, "Supplied logger does not implement:debug"
      end
    end

    describe ".factory" do
      describe "batching an appender that cannot be batched" do
        let(:block) { ->(log, _logger) { log.message } }
        let(:advice) { "Give it a formatter that implements #batch(logs, logger), or add it with batch: false." }

        # Creates the appender without connecting to its server.
        def factory(**, &)
          stub_http_start { SemanticLogger::Appender.factory(**, &) }
        end

        {
          SemanticLogger::Appender::Http   => {appender: :http, url: "http://localhost:8088/path"},
          SemanticLogger::Appender::Loki   => {appender: :loki, url: "http://localhost:3100"},
          SemanticLogger::Metric::Signalfx => {metric: :signalfx, token: "TEST"}
        }.each_pair do |appender_class, options|
          it "raises ArgumentError for #{options.values.first.inspect} with batch: true and a formatter block" do
            error = assert_raises(ArgumentError) { factory(**options, batch: true, &block) }

            assert_equal "add_appender cannot batch #{appender_class}: its formatter, Proc, cannot format a batch. " \
                         "#{advice}",
                         error.message
          end

          it "batches a subclass of #{appender_class.name.split('::').last} whose own #batch formats each log " \
             "message, with a formatter block" do
            subclass = Class.new(appender_class) do
              def written
                @written ||= []
              end

              def batch(logs)
                logs.each { |log| written << format_log(log) }
              end
            end
            appender = stub_http_start { subclass.new(**options.except(:appender, :metric), &block) }
            added    = factory(options.keys.first => appender, batch: true)
            log      = SemanticLogger::Log.new("Test", :info).tap { |entry| entry.message = "hello" }
            added.log(log)
            added.flush

            assert_equal ["hello"], appender.written
          ensure
            added&.close
          end
        end

        it "names the formatter, and says to give it one that implements #batch, or to add it with batch: false" do
          error = assert_raises(ArgumentError) do
            factory(appender: :http, url: "http://localhost:8088/path", batch: true, formatter: :default)
          end

          assert_equal "add_appender cannot batch SemanticLogger::Appender::Http: its formatter, " \
                       "SemanticLogger::Formatters::Default, cannot format a batch. #{advice}",
                       error.message
        end

        it "says only to add :splunk_http with batch: false, since it is its own formatter" do
          error = assert_raises(ArgumentError) do
            factory(appender: :splunk_http, url: "http://localhost:8088/path", token: "TEST", batch: true)
          end

          assert_equal "add_appender cannot batch SemanticLogger::Appender::SplunkHttp: it is its own formatter, " \
                       "which cannot format a batch. Add it with batch: false.",
                       error.message
        end

        it "raises ArgumentError with the refusal that a custom appender gives, even when batched by default" do
          appender = Class.new(SemanticLogger::Subscriber) do
            def batch(logs) = logs

            def batch_refusal = "its server takes one entry at a time. Add it with batch: false."
          end.new

          error = assert_raises(ArgumentError) { factory(appender: appender) }

          assert_equal "add_appender cannot batch #{appender.class}: its server takes one entry at a time. " \
                       "Add it with batch: false.",
                       error.message
        end

        it "raises ArgumentError for an appender batched by default" do
          batched = Class.new(SemanticLogger::Appender::Http) do
            def batch_by_default? = true
          end

          appender = stub_http_start { batched.new(url: "http://localhost:8088/path", &block) }

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

      describe "when it fails after creating the appender" do
        let(:block) { ->(log, _logger) { log.message } }

        # Creates the appender without connecting to its server.
        def factory(**, &)
          stub_http_start { SemanticLogger::Appender.factory(**, &) }
        end

        it "closes the connection of the appender that it created before raising" do
          finished = []

          Net::HTTP.stub_any_instance(:finish, -> { finished << self }) do
            assert_raises(ArgumentError) do
              factory(appender: :http, url: "http://localhost:8088/path", batch: true, &block)
            end
          end

          assert_equal 1, finished.size
        end

        it "closes the appender that it created when it cannot batch it for another reason" do
          closed = []

          # Its #reopen closes the socket it replaces, of which there is none when it is created.
          SemanticLogger::Appender::Udp.stub_any_instance(:close, -> { closed << @socket if @socket }) do
            error = assert_raises(ArgumentError) do
              factory(appender: :udp, server: "localhost:2000", metrics: false, batch: true)
            end

            assert_includes error.message, "does not support batching"
          end

          assert_equal 1, closed.size
        ensure
          closed.each(&:close)
        end

        it "raises the error that it failed with, when closing the appender fails too" do
          SemanticLogger::Appender::Http.stub_any_instance(:close, -> { raise IOError, "closing" }) do
            error = assert_raises(ArgumentError) do
              factory(appender: :http, url: "http://localhost:8088/path", batch: true, &block)
            end

            assert_includes error.message, "add_appender cannot batch SemanticLogger::Appender::Http:"
          end
        end

        it "leaves open an appender instance given as appender: or metric:, which the caller holds" do
          appender = factory(appender: :http, url: "http://localhost:8088/path", &block)
          metric   = factory(metric: :signalfx, token: "TEST", &block)
          closed   = []
          [[:appender, appender], [:metric, metric]].each do |option, instance|
            instance.stub(:close, -> { closed << option }) do
              assert_raises(ArgumentError) { factory(option => instance, batch: true) }
            end
          end

          assert_empty closed
        end

        it "leaves open the logger given as logger:, which the caller holds, and the stream it writes to" do
          io = StringIO.new

          assert_raises(ArgumentError) { factory(logger: Logger.new(io), batch: true) }

          refute_predicate io, :closed?
        end

        it "closes the appender that it created for file_name:, though also given logger:, which it ignores" do
          file_name = File.join(Dir.tmpdir, "semantic_logger_appender_test_#{Process.pid}.log")
          io        = StringIO.new
          closed    = []

          SemanticLogger::Appender::File.stub_any_instance(:close, -> { closed << self }) do
            assert_deprecated(/it uses file_name: and ignores logger:,/) do
              error = assert_raises(ArgumentError) do
                factory(file_name: file_name, logger: Logger.new(io), batch: true)
              end

              assert_includes error.message, "does not support batching"
            end
          end

          assert_equal 1, closed.size
          assert_instance_of SemanticLogger::Appender::File, closed.first
          refute_predicate io, :closed?
        ensure
          FileUtils.rm_f(file_name)
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
