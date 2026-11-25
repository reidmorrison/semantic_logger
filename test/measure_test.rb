require_relative "test_helper"

class MeasureTest < Minitest::Test
  include ExceptionFixtures

  describe "Measure" do
    let(:appender) { SemanticLogger::Test::CaptureLogEvents.new }
    let(:payload) { {session_id: "HSSKLEU@JDK767", tracking_number: 12_345, message: "Message from payload"} }
    let(:metric) { "supplier/call" }
    let(:dimensions) { {supplier: "acme", region: "us"} }

    # Ensure that any log level can be measured and logged
    SemanticLogger::LEVELS.each do |level|
      measure_level = :"measure_#{level}"

      describe "##{measure_level}" do
        it "logs" do
          assert_equal "result", appender.send(measure_level, "hello world", payload: payload) { "result" }

          assert log = appender.events.first
          assert_equal "hello world", log.message
          assert_equal level, log.level
          assert_equal payload, log.payload
        end

        describe ":min_duration" do
          it "not log when faster" do
            assert_equal "result", appender.send(measure_level, "hello world", min_duration: 2000) { "result" }
            assert_empty appender.events
          end

          it "log when slower" do
            assert_equal "result", appender.send(measure_level, "hello world", min_duration: 200, payload: payload) {
              sleep 0.5
              "result"
            }

            assert log = appender.events.first
            assert_equal "hello world", log.message
          end
        end

        it ":exception" do
          assert_raises RuntimeError do
            appender.send(measure_level, "hello world", payload: payload) { raise "Test" }
          end

          assert log = appender.events.first
          refute log.exception
          assert_equal "hello world -- Exception: RuntimeError: Test", log.message
          assert_equal level, log.level
        end

        it ":on_exception_level" do
          assert_raises RuntimeError do
            appender.measure(level, "hello world", payload: payload, on_exception_level: :fatal) { raise "Test" }
          end

          assert log = appender.events.first
          refute log.exception
          assert_equal "hello world -- Exception: RuntimeError: Test", log.message
          assert_equal :fatal, log.level
        end

        describe "log_exception" do
          it "default" do
            assert_raises RuntimeError do
              appender.send(measure_level, "hello world") { raise "Test" }
            end

            assert log = appender.events.first
            refute log.exception
            assert_equal "hello world -- Exception: RuntimeError: Test", log.message
          end

          it ":full" do
            assert_raises RuntimeError do
              appender.send(measure_level, "hello world", log_exception: :full) { raise "Test" }
            end

            assert log = appender.events.first
            assert_kind_of RuntimeError, log.exception
            assert log.exception.backtrace
            assert_equal level, log.level
            assert_equal "hello world", log.message
          end

          it ":partial" do
            assert_raises RuntimeError do
              appender.send(measure_level, "hello world", log_exception: :partial) { raise "Test" }
            end

            assert log = appender.events.first
            refute log.exception
            assert_equal "hello world -- Exception: RuntimeError: Test", log.message
          end

          it ":partial with a cause" do
            assert_raises RuntimeError do
              appender.send(measure_level, "hello world", log_exception: :partial) do
                raise IOError, "disk full"
              rescue IOError
                raise "Test"
              end
            end

            assert log = appender.events.first
            refute log.exception
            assert_equal "hello world -- Exception: RuntimeError: Test -- Cause: IOError: disk full", log.message
          end

          it ":partial re-raises an exception whose message is in another encoding" do
            error = assert_raises RuntimeError do
              appender.send(measure_level, "Grüße", log_exception: :partial) { raise "Datei \xFC kaputt".b }
            end

            assert_equal "Datei \xFC kaputt".b, error.message
            assert log = appender.events.first
            assert_equal "Grüße -- Exception: RuntimeError: Datei  kaputt", log.message
          end

          it ":partial re-raises an exception whose #message raises" do
            assert_raises BrokenMessageError do
              appender.send(measure_level, "hello world", log_exception: :partial) do
                raise BrokenMessageError, "Order 7"
              end
            end

            assert log = appender.events.first
            assert_equal "hello world -- Exception: ExceptionFixtures::BrokenMessageError: Order 7", log.message
          end

          it ":partial re-raises the exception when the #message of its cause raises" do
            assert_raises RuntimeError do
              appender.send(measure_level, "hello world", log_exception: :partial) do
                raise BrokenMessageError, "Order 7"
              rescue BrokenMessageError
                raise "Test"
              end
            end

            assert log = appender.events.first
            assert_equal "hello world -- Exception: RuntimeError: Test " \
                         "-- Cause: ExceptionFixtures::BrokenMessageError: Order 7", log.message
          end

          it ":partial re-raises an exception whose class raises when asked for its name" do
            assert_raises UnnameableError do
              appender.send(measure_level, "hello world", log_exception: :partial) do
                raise UnnameableError, "Order 7"
              end
            end

            assert log = appender.events.first
            assert_equal "hello world -- Exception: ExceptionFixtures::UnnameableError: Order 7", log.message
          end

          it ":none" do
            assert_raises RuntimeError do
              appender.send(measure_level, "hello world", log_exception: :none) { raise "Test" }
            end

            assert log = appender.events.first
            refute log.exception
            assert_equal "hello world", log.message
          end
        end

        it ":metric" do
          metric_name = "/my/custom/metric"

          assert_equal "result", appender.send(measure_level, "hello world", metric: metric_name) { "result" }

          assert log = appender.events.first
          assert_equal metric_name, log.metric
        end

        describe ":dimensions" do
          it "with a block" do
            assert_equal "result", appender.send(measure_level, "hello world", metric: metric, dimensions: dimensions) {
              "result"
            }

            assert log = appender.events.first
            assert_equal metric, log.metric
            assert_equal dimensions, log.dimensions
            assert_predicate log, :dimensions?
          end

          it "with :duration" do
            appender.send(measure_level, "hello world", metric: metric, dimensions: dimensions, duration: 12.5)

            assert log = appender.events.first
            assert_in_delta 12.5, log.duration
            assert_equal dimensions, log.dimensions
            assert_predicate log, :dimensions?
          end
        end

        it ":dimensions with the deprecated #benchmark_#{level}" do
          result = assert_deprecated(/benchmark_#{level} is deprecated and removed in v6\. Use measure_#{level},/) do
            appender.send(:"benchmark_#{level}", "hello world", metric: metric, dimensions: dimensions) { "result" }
          end

          assert_equal "result", result
          assert log = appender.events.first
          assert_equal dimensions, log.dimensions
        end

        it ":backtrace_level" do
          SemanticLogger.stub(:backtrace_level_index, 0) do
            assert_equal "result", appender.send(measure_level, "hello world") { "result" }

            assert log = appender.events.first
            assert log.backtrace
            assert_predicate log.backtrace.size, :positive?

            # Extract file name and line number from backtrace
            h = log.to_h

            assert_match(/measure_test.rb/, h[:file], h)
            assert_kind_of Integer, h[:line]
          end
        end
      end

      describe "#measure(#{level})" do
        it ":message" do
          assert_equal "result", appender.measure(level, "hello world") { "result" }

          assert log = appender.events.first
          assert_equal "hello world", log.message
        end

        it ":level" do
          assert_equal "result", appender.measure(level, "hello world") { "result" }

          assert log = appender.events.first
          assert_equal level, log.level
        end

        it ":payload" do
          assert_equal "result", appender.measure(level, "hello world", payload: payload) { "result" }

          assert log = appender.events.first
          assert_equal payload, log.payload
        end

        describe ":min_duration" do
          it "not log when faster" do
            assert_equal "result", appender.measure(level, "hello world", min_duration: 2000) { "result" }
            assert_empty appender.events
          end

          it "log when slower" do
            assert_equal "result", appender.measure(level, "hello world", min_duration: 200, payload: payload) {
              sleep 0.5
              "result"
            }
            assert log = appender.events.first
            assert_equal "hello world", log.message
          end
        end

        it ":exception" do
          assert_raises RuntimeError do
            appender.measure(level, "hello world", payload: payload) { raise "Test" }
          end

          assert log = appender.events.first
          refute log.exception
          assert_equal "hello world -- Exception: RuntimeError: Test", log.message
          assert_equal level, log.level
        end

        it ":on_exception_level" do
          assert_raises RuntimeError do
            appender.measure(level, "hello world", payload: payload, on_exception_level: :fatal) { raise "Test" }
          end

          assert log = appender.events.first
          refute log.exception
          assert_equal "hello world -- Exception: RuntimeError: Test", log.message
          assert_equal :fatal, log.level
        end

        it ":metric" do
          metric_name = "/my/custom/metric"

          assert_equal "result", appender.measure(level, "hello world", metric: metric_name) { "result" }

          assert log = appender.events.first
          assert_equal metric_name, log.metric
        end

        it ":dimensions" do
          assert_equal "result",
                       appender.measure(level, "hello world", metric: metric, dimensions: dimensions) { "result" }

          assert log = appender.events.first
          assert_equal dimensions, log.dimensions
        end

        it ":dimensions with the deprecated #benchmark(#{level})" do
          result = assert_deprecated(/benchmark is deprecated and removed in v6\. Use measure,/) do
            appender.benchmark(level, "hello world", metric: metric, dimensions: dimensions) { "result" }
          end

          assert_equal "result", result
          assert log = appender.events.first
          assert_equal dimensions, log.dimensions
        end

        unless level == :fatal
          it "the deprecated #benchmark(#{level}) runs the block below the level" do
            appender.level = :fatal
            result = assert_deprecated(/benchmark is deprecated/) do
              appender.benchmark(level, "hello world") { |params| params }
            end

            assert_equal({}, result)
            assert_empty appender.events
          end
        end

        it ":backtrace_level" do
          SemanticLogger.stub(:backtrace_level_index, 0) do
            assert_equal "result", appender.measure(level, "hello world") { "result" }

            assert log = appender.events.first
            assert log.backtrace
            assert_predicate log.backtrace.size, :positive?

            # Extract file name and line number from backtrace
            h = log.to_h

            assert_match(/measure_test.rb/, h[:file], h)
            assert_kind_of Integer, h[:line]
          end
        end
      end

      describe "##{measure_level} keyword arguments" do
        it ":message" do
          assert_equal "result", appender.send(measure_level, message: "hello world") { "result" }

          assert log = appender.events.first
          assert_equal "hello world", log.message
        end

        it ":level" do
          assert_equal "result", appender.send(measure_level, message: "hello world") { "result" }

          assert log = appender.events.first
          assert_equal level, log.level
        end

        it ":payload" do
          assert_equal "result", appender.send(measure_level, message: "hello world", payload: payload) { "result" }

          assert log = appender.events.first
          assert_equal payload, log.payload
        end

        describe ":min_duration" do
          it "not log when faster" do
            assert_equal "result", appender.send(measure_level, message: "hello world", min_duration: 2000) { "result" }
            assert_empty appender.events
          end

          it "log when slower" do
            assert_equal "result",
                         appender.send(measure_level, message: "hello world", min_duration: 200, payload: payload) {
                           sleep 0.5
                           "result"
                         }

            assert log = appender.events.first
            assert_equal "hello world", log.message
          end
        end

        it ":exception" do
          assert_raises RuntimeError do
            appender.send(measure_level, message: "hello world", payload: payload) { raise "Test" }
          end

          assert log = appender.events.first
          refute log.exception
          assert_equal "hello world -- Exception: RuntimeError: Test", log.message
          assert_equal level, log.level
        end

        it ":on_exception_level" do
          assert_raises RuntimeError do
            appender.send(measure_level, message: "hello world", payload: payload, on_exception_level: :fatal) do
              raise "Test"
            end
          end

          assert log = appender.events.first
          refute log.exception
          assert_equal "hello world -- Exception: RuntimeError: Test", log.message
          assert_equal :fatal, log.level
        end

        it ":metric" do
          metric_name = "/my/custom/metric"

          assert_equal "result", appender.send(measure_level, message: "hello world", metric: metric_name) { "result" }

          assert log = appender.events.first
          assert_equal metric_name, log.metric
        end

        it ":dimensions" do
          assert_equal "result",
                       appender.send(measure_level, message: "hello world", metric: metric, dimensions: dimensions) {
                         "result"
                       }

          assert log = appender.events.first
          assert_equal "hello world", log.message
          assert_equal dimensions, log.dimensions
        end

        it ":dimensions with :duration" do
          appender.send(measure_level, message: "hello world", metric: metric, dimensions: dimensions, duration: 12.5)

          assert log = appender.events.first
          assert_in_delta 12.5, log.duration
          assert_equal dimensions, log.dimensions
        end

        it ":backtrace_level" do
          SemanticLogger.stub(:backtrace_level_index, 0) do
            assert_equal "result", appender.send(measure_level, message: "hello world") { "result" }

            assert log = appender.events.first
            assert log.backtrace
            assert_predicate log.backtrace.size, :positive?

            # Extract file name and line number from backtrace
            h = log.to_h

            assert_match(/measure_test.rb/, h[:file], h)
            assert_kind_of Integer, h[:line]
          end
        end
      end
    end

    describe "return" do
      it "log when the block performs a return" do
        assert_equal "Good", function_with_return(appender)

        assert log = appender.events.first
        assert_equal "hello world", log.message
      end
    end

    describe ":silence" do
      let(:appender) { SemanticLogger::Test::CaptureLogEvents.new(level: nil) }

      it "silences messages" do
        appender.measure_info("hello world", silence: :error) do
          appender.warn "don't log me"
        end

        assert_equal 1, appender.events.count, -> { appender.events.to_h.ai }
        assert log = appender.events.first
        assert_equal "hello world", log.message
        assert_equal :info, log.level
      end

      it "does not silence higher level messages" do
        first = nil
        appender.measure_info("hello world", silence: :trace) do
          appender.debug("hello world", payload) { "Calculations" }
          first = appender.events.first
        end

        assert_equal "hello world -- Calculations", first.message
        assert_equal payload, first.payload

        assert log = appender.events.last
        assert_equal "hello world", log.message
      end
    end

    describe "untrusted options" do
      it "ignores option values that are not valid for them" do
        untrusted = {
          min_duration:       "x",
          metric_amount:      Complex(1, 1),
          log_exception:      :off,
          on_exception_level: 2**70,
          silence:            "bogus",
          exception:          "not an exception",
          dimensions:         [%i[supplier acme]]
        }

        assert_equal "result", appender.measure_info("hello world", untrusted) { "result" }

        assert log = appender.events.first
        assert_equal "hello world", log.message
        assert_equal :info, log.level
        assert_nil log.metric_amount
        assert_nil log.exception
        assert_nil log.dimensions
      end

      it "keeps the metric when its dimensions are not a Hash" do
        assert_equal "result", appender.measure_info("hello world", metric: metric, dimensions: "acme") { "result" }

        assert log = appender.events.first
        assert_equal metric, log.metric
        assert_nil log.dimensions
        refute_predicate log, :dimensions?
        assert_nil log.payload
      end

      it "ignores dimensions that are not a Hash with :duration" do
        appender.measure_info("hello world", metric: metric, dimensions: "acme", duration: 12.5)

        assert log = appender.events.first
        assert_equal metric, log.metric
        assert_nil log.dimensions
      end

      it "uses the defaults for invalid values when the block raises" do
        assert_raises RuntimeError do
          appender.measure_info("hello world", log_exception: "full", on_exception_level: 99) { raise "Test" }
        end

        assert log = appender.events.first
        assert_equal "hello world -- Exception: RuntimeError: Test", log.message
        assert_equal :info, log.level
      end

      it "stores an on_exception_level supplied as a String as its Symbol" do
        assert_raises RuntimeError do
          appender.measure_info("hello world", on_exception_level: "error") { raise "Test" }
        end

        assert log = appender.events.first
        assert_equal :error, log.level
      end

      it "requires a valid duration when no block is supplied" do
        assert_raises RuntimeError do
          appender.measure_info("hello world", duration: "12")
        end
      end
    end

    describe "with a logger and an appender" do
      include InMemoryAppenderHelper

      it "writes the dimensions of a measured metric to the appender" do
        logger.measure_info("Called supplier", metric: metric, dimensions: dimensions) { "result" }

        assert log = log_message
        assert_equal "Called supplier", log.message
        assert_equal metric, log.metric
        assert_equal dimensions, log.dimensions
        assert_kind_of Float, log.duration
      end

      it "writes the dimensions of a metric measured with :duration to the appender" do
        logger.measure_info("Called supplier", metric: metric, dimensions: dimensions, duration: 12.5)

        assert log = log_message
        assert_equal dimensions, log.dimensions
        assert_in_delta 12.5, log.duration
      end
    end

    # Make sure that measure still logs when a block uses return to return from
    # a function
    def function_with_return(appender)
      appender.measure_info("hello world", payload: payload) do
        return "Good"
      end
      "Bad"
    end
  end
end
