require_relative "../test_helper"
require "open3"

module Metric
  class SummaryTest < Minitest::Test
    describe SemanticLogger::Metric::Summary do
      let(:logger) { SemanticLogger["SummaryTest"] }
      let(:captured) { SemanticLogger::Test::CaptureLogEvents.new }
      let(:summary_name) { "SemanticLogger::Metric::Summary" }

      # Returns [Array<SemanticLogger::Log>] the summary entries that the capturing appender was given.
      def entries(appender = captured)
        appender.events.select { |log| log.name == summary_name }
      end

      def entry(message, appender = captured)
        entries(appender).find { |log| log.message == message }
      end

      after do
        SemanticLogger.appenders.dup.each do |added|
          SemanticLogger.remove_appender(added) if added.metrics_interval || added.equal?(captured)
        end
      end

      describe "added with add_appender" do
        it "is a metric appender, with an interval of 60 seconds and :info entries by default" do
          summary = SemanticLogger.add_appender(metric: :summary)

          assert_instance_of SemanticLogger::Metric::Summary, summary
          assert_equal 60, summary.metrics_interval
          assert_equal :info, summary.level
          refute_predicate summary, :internal_metrics?
        end

        it "takes the interval and level of its entries" do
          summary = SemanticLogger.add_appender(metric: :summary, interval: 300, level: :debug)

          assert_equal 300, summary.metrics_interval
          assert_equal :debug, summary.level
        end

        it "writes :info entries when given level: nil, whatever the default level" do
          SemanticLogger.stub(:default_level, :warn) do
            summary = SemanticLogger.add_appender(metric: :summary, level: nil)

            assert_equal :info, summary.level
            assert_equal SemanticLogger::Levels.index(:info), summary.send(:level_index)
          end
        end

        it "refuses filter:, since it takes no log entries" do
          error = assert_raises(ArgumentError) { SemanticLogger.add_appender(metric: :summary, filter: /Test/) }

          assert_includes error.message, "filter:"
        end

        it "takes no log entries" do
          summary = SemanticLogger.add_appender(metric: :summary)

          refute summary.should_log?(SemanticLogger::Log.new("Test", :fatal))
        end
      end

      describe "the entries" do
        before do
          SemanticLogger.add_appender(appender: captured, batch: false)
        end

        it "writes a counter as its sum" do
          SemanticLogger.add_appender(metric: :summary)
          logger.increment("users.signup")
          logger.increment("users.signup", 2)
          SemanticLogger.flush

          log = entry("users.signup")

          assert_equal :info, log.level
          assert_equal({sum: 3}, log.payload)
          assert_nil log.metric
          assert_nil log.dimensions
        end

        it "writes a histogram as its count, sum, min, max, and percentiles, rounded" do
          SemanticLogger.add_appender(metric: :summary)
          100.times { |i| logger.time("supplier.add_user", duration: (i + 1) * 10.0) }
          SemanticLogger.flush

          payload = entry("supplier.add_user").payload

          assert_equal %i[count sum min max p50 p95 p99 unit], payload.keys
          assert_equal 100, payload[:count]
          assert_in_delta 50.5, payload[:sum], 0.01
          assert_in_delta 0.01, payload[:min], 0.0001
          assert_in_delta 1.0, payload[:max], 0.001
          assert_in_delta 0.5, payload[:p50], 0.05
          assert_in_delta 0.95, payload[:p95], 0.1
          assert_in_delta 0.99, payload[:p99], 0.1
          assert_equal "s", payload[:unit]
          payload.values_at(:sum, :min, :max, :p50, :p95, :p99).each do |value|
            assert_equal value, value.round(4), "#{value} should be rounded to 3 significant digits"
          end
        end

        it "writes the unit of a histogram of any value" do
          SemanticLogger.add_appender(metric: :summary)
          logger.record("upload.size", 2048, unit: "By")
          SemanticLogger.flush

          payload = entry("upload.size").payload

          assert_equal 1, payload[:count]
          assert_equal "By", payload[:unit]
        end

        it "writes the dimensions of a series in its payload, one entry per series" do
          SemanticLogger.add_appender(metric: :summary)
          logger.increment("cart.items_added", 3, dimensions: {department: "clothing"})
          logger.increment("cart.items_added", 1, dimensions: {department: "toys"})
          SemanticLogger.flush

          payloads = entries.select { |log| log.message == "cart.items_added" }.map(&:payload)

          assert_equal 2, payloads.size
          assert_includes payloads, {sum: 3, dimensions: {"department" => "clothing"}}
          assert_includes payloads, {sum: 1, dimensions: {"department" => "toys"}}
        end

        it "writes its entries at its level, which each log appender filters by its own" do
          warn_only = SemanticLogger::Test::CaptureLogEvents.new(level: :warn)
          SemanticLogger.add_appender(appender: warn_only, batch: false)
          SemanticLogger.add_appender(metric: :summary, level: :debug)
          logger.increment("users.signup")
          SemanticLogger.flush

          assert_equal :debug, entry("users.signup").level
          assert_empty entries(warn_only)
        ensure
          SemanticLogger.remove_appender(warn_only)
        end

        it "leaves out Semantic Logger's own metrics, unless it writes them" do
          SemanticLogger.add_appender(metric: :summary)
          SemanticLogger.add_appender(metric: SemanticLogger::Metric::Summary.new(internal_metrics: true))
          SemanticLogger::Metric.collector.record(:counter, "semantic_logger.log.processed", 5, internal: true)
          logger.increment("users.signup")
          SemanticLogger.flush

          processed = entries.select { |log| log.message == "semantic_logger.log.processed" }

          assert_equal 1, processed.size, "only the summary with internal_metrics: true should write it"
          assert_equal({sum: 5}, processed.first.payload)
          assert_equal(2, entries.count { |log| log.message == "users.signup" })
        end

        it "writes no tags or named tags of the thread that writes them" do
          SemanticLogger.add_appender(metric: :summary)
          logger.increment("users.signup")
          SemanticLogger.tagged("request", user: "jack") { SemanticLogger.flush }

          log = entry("users.signup")

          assert_empty log.tags
          assert_empty log.named_tags
        end

        it "writes nothing for an interval without metrics" do
          SemanticLogger.add_appender(metric: :summary)
          SemanticLogger.flush

          assert_empty entries
        end

        it "feeds no metric back: its entries record none" do
          SemanticLogger.add_appender(metric: :summary)
          logger.increment("users.signup")
          SemanticLogger.flush
          SemanticLogger.flush

          assert_equal 1, entries.size
        end

        it "writes them with an appender added with async: true" do
          proxy = SemanticLogger.add_appender(metric: :summary, async: true)

          assert_kind_of SemanticLogger::Appender::Async, proxy

          logger.increment("users.signup")
          SemanticLogger.flush

          assert_equal({sum: 1}, entry("users.signup").payload)
        end
      end

      describe "when flushed" do
        before do
          SemanticLogger.add_appender(appender: captured, batch: false)
        end

        it "has its entries reach the log appenders before SemanticLogger.flush returns" do
          async_captured = SemanticLogger::Test::CaptureLogEvents.new
          proxy          = SemanticLogger.add_appender(appender: async_captured, async: true, batch: false)
          SemanticLogger.add_appender(metric: :summary)
          logger.increment("users.signup")
          SemanticLogger.flush

          refute_nil entry("users.signup")
          refute_nil entry("users.signup", async_captured), "an appender flushed before the summary gets them too"
        ensure
          SemanticLogger.remove_appender(proxy) if proxy
        end

        it "has its entries reach the log appenders in one flush, when added with async: true" do
          async_captured = SemanticLogger::Test::CaptureLogEvents.new
          proxy          = SemanticLogger.add_appender(appender: async_captured, async: true, batch: false)
          SemanticLogger.add_appender(metric: :summary, async: true)
          logger.increment("users.signup")
          processor = SemanticLogger::Logger.processor
          flush     = processor.method(:flush)
          flushes   = 0
          processor.stub(:flush, -> { (flushes += 1) && flush.call }) { SemanticLogger.flush }

          assert_equal 1, flushes
          refute_nil entry("users.signup")
          refute_nil entry("users.signup", async_captured)
        ensure
          SemanticLogger.remove_appender(proxy) if proxy
        end
      end

      # Semantic Logger flushes the appenders in an at_exit hook, so these exit another Ruby, in each
      # processor mode.
      describe "at exit, or on close" do
        # Runs the script in another Ruby, which requires the library, and returns what it wrote.
        def run_ruby(library, script)
          output, status = Open3.capture2e(
            RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-r", library, "-e", script
          )

          assert_predicate status, :success?, output
          output
        end

        # Adds a log appender to $stdout, with async: true when asked, then the summary, records a
        # counter, and then runs the ending, if any, before it exits.
        def script(async:, ending: nil)
          <<~RUBY
            SemanticLogger.add_appender(io: $stdout, formatter: :json, async: #{async})
            SemanticLogger.add_appender(metric: :summary)
            SemanticLogger["Script"].increment("users.signup", 4)
            #{ending}
          RUBY
        end

        %w[semantic_logger semantic_logger/sync].each do |library|
          [false, true].each do |async|
            it "writes the last partial interval with #{library}, async: #{async}" do
              output = run_ruby(library, script(async: async))

              assert_includes output, '"message":"users.signup","payload":{"sum":4}'
            end

            it "writes the last partial interval once closed, with #{library}, async: #{async}" do
              output = run_ruby(library, script(async: async, ending: "SemanticLogger.close"))

              assert_includes output, '"message":"users.signup","payload":{"sum":4}'
            end
          end

          it "writes the last partial interval when added with async: true, with #{library}" do
            output = run_ruby(
              library,
              script(async: true).sub("add_appender(metric: :summary)", "add_appender(metric: :summary, async: true)")
            )

            assert_includes output, '"message":"users.signup","payload":{"sum":4}'
          end
        end
      end

      describe "with a capped main queue that is full" do
        let(:processor) { SemanticLogger::Processor.new(max_queue_size: 1) }

        after do
          thread = processor.processor.instance_variable_get(:@thread)
          thread&.kill
          thread&.join
        end

        it "writes from the processor's own thread without waiting for room on its queue" do
          processor.appenders << captured
          summary = SemanticLogger::Metric::Summary.new(interval: 1)
          processor.appenders << summary
          points = Array.new(5) do |i|
            SemanticLogger::Metric::Snapshot::Point.new(kind: :counter, name: "metric.#{i}", value: i)
          end
          snapshot = SemanticLogger::Metric::Snapshot.new(start_time: Time.now - 1, end_time: Time.now, points: points)

          SemanticLogger::Logger.stub(:processor, processor) do
            processor.log_metrics(snapshot)
            flushing = Thread.new { processor.flush }

            assert flushing.join(5), "the processor's thread should not wait on its own full queue"
          ensure
            flushing&.kill
          end
          deadline = Time.now + 5
          sleep 0.01 while entries.size < 5 && Time.now < deadline

          assert_equal 5, entries.size
        end
      end

      describe "rounding" do
        let(:summary) { SemanticLogger::Metric::Summary.new }

        it "keeps 3 significant digits, and every digit before the decimal point" do
          assert_in_delta 0.0123, summary.send(:rounded, 0.0123456), 1e-12
          assert_in_delta 98.1, summary.send(:rounded, 98.1234), 1e-12
          assert_in_delta(-2.35, summary.send(:rounded, -2.3456), 1e-12)
          assert_equal 1205, summary.send(:rounded, 1204.56)
          assert_equal 7, summary.send(:rounded, 7)
          assert_in_delta 0.0, summary.send(:rounded, 0.0), 0
        end
      end
    end
  end
end
