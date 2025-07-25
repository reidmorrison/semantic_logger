require_relative "test_helper"

class MeasureTest < Minitest::Test
  describe "Measure" do
    let(:appender) { SemanticLogger::Test::CaptureLogEvents.new }
    let(:payload) { {session_id: "HSSKLEU@JDK767", tracking_number: 12_345, message: "Message from payload"} }

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
            assert appender.events.empty?
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
            assert log.exception.is_a?(RuntimeError)
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

        it ":backtrace_level" do
          SemanticLogger.stub(:backtrace_level_index, 0) do
            assert_equal "result", appender.send(measure_level, "hello world") { "result" }

            assert log = appender.events.first
            assert log.backtrace
            assert log.backtrace.size.positive?

            # Extract file name and line number from backtrace
            h = log.to_h
            assert_match(/measure_test.rb/, h[:file], h)
            assert h[:line].is_a?(Integer)
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
            assert appender.events.empty?
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

        it ":backtrace_level" do
          SemanticLogger.stub(:backtrace_level_index, 0) do
            assert_equal "result", appender.measure(level, "hello world") { "result" }

            assert log = appender.events.first
            assert log.backtrace
            assert log.backtrace.size.positive?

            # Extract file name and line number from backtrace
            h = log.to_h
            assert_match(/measure_test.rb/, h[:file], h)
            assert h[:line].is_a?(Integer)
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
            assert appender.events.empty?
          end

          it "log when slower" do
            assert_equal "result", appender.send(measure_level, message: "hello world", min_duration: 200, payload: payload) {
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

        it ":backtrace_level" do
          SemanticLogger.stub(:backtrace_level_index, 0) do
            assert_equal "result", appender.send(measure_level, message: "hello world") { "result" }

            assert log = appender.events.first
            assert log.backtrace
            assert log.backtrace.size.positive?

            # Extract file name and line number from backtrace
            h = log.to_h
            assert_match(/measure_test.rb/, h[:file], h)
            assert h[:line].is_a?(Integer)
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
