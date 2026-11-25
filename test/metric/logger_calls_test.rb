require_relative "../test_helper"

module Metric
  # Logger#increment, #time, and #record.
  class LoggerCallsTest < Minitest::Test
    describe SemanticLogger::Base do
      let(:logger) { SemanticLogger["Metric::LoggerCallsTest"] }
      let(:appender) { InMemoryMetricAppender.new }

      after do
        SemanticLogger.appenders.dup.each do |added|
          SemanticLogger.remove_appender(added) if added.metrics_interval
        end
      end

      # Runs the block, discarding the warnings about the metrics it drops.
      def without_warnings(&)
        SemanticLogger::Logger.processor.logger.stub(:warn, nil, &)
      end

      # Returns [Array<SemanticLogger::Metric::Snapshot::Point>] the points written once flushed.
      def points
        SemanticLogger.flush
        appender.points
      end

      describe "without a metric appender" do
        it "records nothing, and returns false" do
          refute logger.increment("users.signup")
          refute logger.record("order.items", 3)
          refute logger.time("supplier.add_user", duration: 12)
        end

        it "returns the result of the block timed" do
          assert_equal 42, logger.time("supplier.add_user") { 42 }
        end

        it "calls the block of #time without reading the clock or calling its dimensions" do
          dimensions = ->(*) { flunk "dimensions called" }

          test_thread = Thread.current
          clock       = Process.method(:clock_gettime)
          # Only this thread's clock reads fail, so that the background threads are left to run.
          read_clock = lambda do |*args|
            flunk "clock read" if Thread.current == test_thread

            clock.call(*args)
          end

          Process.stub(:clock_gettime, read_clock) do
            assert_equal 42, logger.time("supplier.add_user", dimensions: dimensions) { 42 }
          end
          refute logger.time("supplier.add_user", duration: 12, dimensions: dimensions)
        end
      end

      describe "when the processor raises" do
        let(:internal_logger) { SemanticLogger::Test::CaptureLogEvents.new }
        let(:processor) do
          failing = Struct.new(:logger).new(internal_logger)
          failing.define_singleton_method(:collecting_metrics?) { true }
          failing.define_singleton_method(:record_metric) { |*, **| raise "boom" }
          failing
        end

        it "returns false, reporting it once per metric name" do
          SemanticLogger::Logger.stub(:processor, processor) do
            refute logger.increment("logger_calls.failing_processor")
            refute logger.increment("logger_calls.failing_processor")
            assert_equal 42, logger.time("logger_calls.failing_processor") { 42 }
          end
          warnings = internal_logger.events.map(&:message)

          assert_equal 1, warnings.size
          assert_includes warnings.first, 'Failed to record counter "logger_calls.failing_processor": RuntimeError'
        end
      end

      describe "with a metric appender" do
        before do
          SemanticLogger.add_appender(metric: appender)
        end

        describe "scope" do
          let(:appender) do
            scoped = InMemoryMetricAppender.new
            scoped.define_singleton_method(:metric_scopes?) { true }
            scoped
          end

          it "is the name of the logger, for each kind of call" do
            logger.increment("users.signup")
            logger.record("order.items", 3)
            logger.time("supplier.add_user", duration: 12)
            logger.info("Signed up", metric: "users.signed_up")
            SemanticLogger["Other"].increment("users.signup")

            assert_equal(
              [["Metric::LoggerCallsTest", "users.signup"], ["Metric::LoggerCallsTest", "order.items"],
               ["Metric::LoggerCallsTest", "supplier.add_user"], ["Metric::LoggerCallsTest", "users.signed_up"],
               ["Other", "users.signup"]],
              points.map { |point| [point.scope, point.name] }
            )
          end
        end

        describe "#increment" do
          it "adds 1 to a counter" do
            assert logger.increment("users.signup")
            assert logger.increment("users.signup")
            point = points.first

            assert_equal :counter, point.kind
            assert_equal "users.signup", point.name
            assert_equal 2, point.value
            assert_nil point.unit
          end

          it "adds the amount given, in the series of its dimensions" do
            logger.increment("cart.items_added", 3, dimensions: {department: "clothing"})
            logger.increment("cart.items_added", 2.5, dimensions: {department: "clothing"})
            logger.increment("cart.items_added", 1, dimensions: {department: "shoes"})
            values = points.to_h { |point| [point.dimensions, point.value] }

            assert_equal({{"department" => "clothing"} => 5.5, {"department" => "shoes"} => 1}, values)
          end

          it "records the unit given, as part of the series" do
            logger.increment("messaging.client.sent.messages", unit: "{message}")
            logger.increment("messaging.client.sent.messages", 2, unit: "{message}")

            assert_equal([["{message}", 3]], points.map { |point| [point.unit, point.value] })
          end

          it "records a Symbol name as a String" do
            logger.increment(:"users.signup")

            assert_equal ["users.signup"], points.map(&:name)
          end

          it "drops a negative amount, warning on the internal logger" do
            warnings = []

            SemanticLogger::Logger.processor.logger.stub(:warn, ->(message) { warnings << message }) do
              # A name of its own, since the collector warns once per name for the whole process.
              refute logger.increment("logger_calls.negative", -1)
            end
            logger.increment("logger_calls.negative")

            assert_equal [1], points.map(&:value)
            assert_equal 1, warnings.size
            assert_includes warnings.first, 'Dropped counter "logger_calls.negative"'
          end
        end

        describe "#time" do
          it "records how long the block takes, in seconds, and returns its result" do
            result = logger.time("supplier.add_user") do
              sleep 0.01
              :added
            end
            point = points.first

            assert_equal :added, result
            assert_equal :histogram, point.kind
            assert_equal "s", point.unit
            assert_equal 1, point.value.count
            assert_operator point.value.min, :>=, 0.01
            assert_operator point.value.max, :<, 1
          end

          it "records the time, and raises again, when the block raises" do
            assert_raises(ArgumentError) do
              logger.time("supplier.add_user") { raise ArgumentError, "boom" }
            end

            assert_equal 1, points.first.value.count
          end

          it "records the time when the block breaks out early" do
            result = logger.time("supplier.add_user") { break :early }

            assert_equal :early, result
            assert_equal 1, points.first.value.count
          end

          it "records the time when the block returns from its method" do
            caller_method = lambda do
              logger.time("supplier.add_user") { return :early }
              :late
            end

            assert_equal :early, caller_method.call
            assert_equal 1, points.first.value.count
          end

          it "records a duration given in milliseconds, in seconds" do
            assert logger.time("sidekiq.queue.latency", duration: 1500, dimensions: {queue: "default"})
            point = points.first

            assert_equal "s", point.unit
            assert_equal({"queue" => "default"}, point.dimensions)
            assert_in_delta 1.5, point.value.sum
          end

          it "returns false, reporting it, for a duration that raises as it is converted to seconds" do
            duration = Class.new(Numeric) { def fdiv(*) = raise(ArgumentError, "fdiv") }.new
            warnings = []

            SemanticLogger::Logger.processor.logger.stub(:warn, ->(message) { warnings << message }) do
              refute logger.time("logger_calls.failing_duration", duration: duration)
            end

            assert_empty points
            assert_includes warnings.first, 'Failed to record histogram "logger_calls.failing_duration": ArgumentError'
          end

          it "times the block, ignoring duration:, when given both" do
            logger.time("supplier.add_user", duration: 60_000) { nil }

            assert_operator points.first.value.max, :<, 1
          end

          it "adds the error.type of what the block raised to its dimensions" do
            assert_raises(ArgumentError) do
              logger.time("supplier.add_user", dimensions: {supplier: "acme"}) { raise ArgumentError, "boom" }
            end
            logger.time("supplier.add_user", dimensions: {supplier: "acme"}) { :added }

            assert_equal [{"supplier" => "acme", "error.type" => "ArgumentError"}, {"supplier" => "acme"}],
                         points.map(&:dimensions)
          end

          describe "with dimensions given as a callable" do
            it "calls it with the block's result, once the block has returned" do
              calls  = []
              result = logger.time("supplier.add_user", dimensions: lambda { |result, error|
                calls << [result, error]
                {outcome: result}
              }) { :added }

              assert_equal :added, result
              assert_equal [[:added, nil]], calls
              assert_equal [{"outcome" => "added"}], points.map(&:dimensions)
            end

            it "calls it with what the block raised, adding its error.type, and raises it again" do
              calls = []
              error = assert_raises(ArgumentError) do
                logger.time("supplier.add_user", dimensions: lambda { |result, error|
                  calls << [result, error]
                  {supplier: "acme"}
                }) { raise ArgumentError, "boom" }
              end

              assert_equal [[nil, error]], calls
              assert_equal [{"supplier" => "acme", "error.type" => "ArgumentError"}], points.map(&:dimensions)
            end

            it "keeps the error.type that it returns, as a String or Symbol key" do
              handled = Class.new(StandardError)
              assert_raises(handled) do
                logger.time("sidekiq.job.duration", dimensions: ->(*) { {"error.type" => "JobError"} }) do
                  raise handled
                end
              end
              assert_raises(handled) do
                logger.time("sidekiq.job.duration", dimensions: ->(*) { {"error.type": "OtherError"} }) do
                  raise handled
                end
              end

              recorded = points.map(&:dimensions).sort_by { |dimensions| dimensions["error.type"] }

              assert_equal [{"error.type" => "JobError"}, {"error.type" => "OtherError"}], recorded
            end

            it "adds an error.type to nil dimensions" do
              assert_raises(ArgumentError) do
                logger.time("supplier.add_user", dimensions: ->(*) {}) { raise ArgumentError, "boom" }
              end

              assert_equal [{"error.type" => "ArgumentError"}], points.map(&:dimensions)
            end

            it "is not called without a block and without a Numeric duration" do
              without_warnings do
                refute logger.time("sidekiq.queue.latency", duration: "1500", dimensions: ->(*) { flunk "called" })
                refute logger.time("sidekiq.queue.latency", dimensions: ->(*) { flunk "called" })
              end

              assert_empty points
            end

            it "raises an exception that is not a StandardError, as from the block" do
              assert_raises(NotImplementedError) do
                logger.time("supplier.add_user", dimensions: ->(*) { raise NotImplementedError }) { :added }
              end
            end

            it "calls it with nil and nil without a block" do
              calls = []

              assert logger.time("db.client.operation.duration", duration: 12, dimensions: lambda { |*args|
                calls << args
                {db: "users"}
              })
              assert_equal [[nil, nil]], calls
              assert_equal [{"db" => "users"}], points.map(&:dimensions)
            end

            it "records nothing, reporting it, when it raises, and returns the block's result" do
              warnings = []

              SemanticLogger::Logger.processor.logger.stub(:warn, ->(message) { warnings << message }) do
                failing = ->(*) { raise NoMethodError, "dimensions" }

                # A name of its own, since the collector reports once per name for the whole process.
                assert_equal :added, logger.time("logger_calls.failing_dimensions", dimensions: failing) { :added }
                assert_raises(ArgumentError) do
                  logger.time("logger_calls.failing_dimensions", dimensions: failing) { raise ArgumentError, "boom" }
                end
                refute logger.time("logger_calls.failing_dimensions", duration: 12, dimensions: failing)
              end

              assert_empty points
              assert_equal 1, warnings.size
              assert_includes warnings.first,
                              'Failed to record histogram "logger_calls.failing_dimensions": NoMethodError'
            end

            it "records nothing, reporting it, when it returns neither a Hash nor nil" do
              warnings = []

              SemanticLogger::Logger.processor.logger.stub(:warn, ->(message) { warnings << message }) do
                assert_equal :added, logger.time("logger_calls.array_dimensions", dimensions: ->(*) { [1] }) { :added }
                assert_raises(ArgumentError) do
                  logger.time("logger_calls.array_dimensions", dimensions: ->(*) { [1] }) { raise ArgumentError }
                end
              end

              assert_empty points
              assert_equal 1, warnings.size
              assert_includes warnings.first, "are not a Hash"
            end

            it "reports a callable that does not take two arguments" do
              warnings = []

              SemanticLogger::Logger.processor.logger.stub(:warn, ->(message) { warnings << message }) do
                assert_equal :added, logger.time("logger_calls.arity_dimensions", dimensions: -> { {} }) { :added }
              end

              assert_empty points
              assert_includes warnings.first,
                              'Failed to record histogram "logger_calls.arity_dimensions": ArgumentError'
            end
          end

          it "drops a duration that is not a Numeric, and a call without a duration or block" do
            without_warnings do
              refute logger.time("sidekiq.queue.latency", duration: "1500")
              refute logger.time("sidekiq.queue.latency")
            end

            assert_empty points
          end
        end

        describe "#record" do
          it "records any value in a histogram, with its unit" do
            logger.record("upload.size", 1024, unit: "By")
            logger.record("upload.size", 4096, unit: "By")
            logger.record("temperature", -3.5)
            upload, temperature = points

            assert_equal :histogram, upload.kind
            assert_equal "By", upload.unit
            assert_equal 2, upload.value.count
            assert_equal 5120, upload.value.sum
            assert_nil temperature.unit
            assert_in_delta(-3.5, temperature.value.min)
          end

          it "drops NaN and Infinity" do
            without_warnings do
              refute logger.record("order.total", Float::NAN)
              refute logger.record("order.total", Float::INFINITY)
            end

            assert_empty points
          end
        end

        it "does not depend on the log level" do
          logger.stub(:level_index, SemanticLogger::Levels.index(:fatal)) do
            logger.increment("users.signup")
          end

          assert_equal ["users.signup"], points.map(&:name)
        end

        it "leaves the tags and named tags out of the dimensions, a child logger's included" do
          child = logger.tagged("request", user_id: 42)
          SemanticLogger.tagged(:outer) do
            SemanticLogger.named_tagged(tenant: "acme") { child.increment("users.signup") }
          end

          assert_equal [{}], points.map(&:dimensions)
        end

        describe "when recording raises" do
          # Dimensions that raise as they are read, so that the Aggregator raises.
          let(:dimensions) { Class.new(Hash) { def each_pair(*) = raise(NoMethodError, "each_pair") }[plan: "free"] }

          it "returns false, reporting it once per metric name" do
            warnings = []
            SemanticLogger::Logger.processor.logger.stub(:warn, ->(message) { warnings << message }) do
              # A name of its own, since the collector reports once per name for the whole process.
              refute logger.increment("logger_calls.failing", dimensions: dimensions)
              refute logger.increment(:"logger_calls.failing", dimensions: dimensions)
            end

            assert_equal 1, warnings.size
            assert_includes warnings.first, 'Failed to record counter "logger_calls.failing": NoMethodError'
          end

          it "raises the exception of the block timed, not the one of recording" do
            without_warnings do
              assert_raises(ArgumentError) do
                logger.time("logger_calls.failing_time", dimensions: dimensions) { raise ArgumentError, "boom" }
              end
            end
          end
        end

        it "can be called on an appender, which inherits them" do
          assert InMemoryAppender.new.increment("users.signup")

          assert_equal ["users.signup"], points.map(&:name)
        end
      end
    end
  end
end
