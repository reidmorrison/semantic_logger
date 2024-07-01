require_relative "test_helper"

# API tests for SemanticLogger
class SemanticLoggerLoggingTest < Minitest::Test
  describe SemanticLogger do
    let(:logger) { SemanticLogger["TestLogger"] }

    SemanticLogger::LEVELS.each_with_index do |level, level_index|
      describe "##{level}" do
        describe "positional arguments logs" do
          it "message only" do
            events = semantic_logger_events do
              logger.send(level, "hello world")
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       :nil,
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "combines message from block" do
            events = semantic_logger_events do
              logger.send(level, "hello world") { "Calculations" }
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world -- Calculations",
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       :nil,
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "message with implied payload" do
            events = semantic_logger_events do
              logger.send(level, "hello world", user_id: 1234)
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       {user_id: 1234},
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "implied payload only" do
            events = semantic_logger_events do
              logger.send(level, user_id: 1234)
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       :nil,
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       {user_id: 1234},
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "message with implied payload and duration" do
            events = semantic_logger_events do
              logger.send(level, "hello world", user_id: 1234, duration: 20.3)
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      20.3,
              payload:       {user_id: 1234},
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "message with explicit payload" do
            events = semantic_logger_events do
              logger.send(level, "hello world", payload: {user_id: 1234})
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       {user_id: 1234},
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "explicit payload only" do
            events = semantic_logger_events do
              logger.send(level, payload: {user_id: 1234})
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       :nil,
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       {user_id: 1234},
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "message and payload from block" do
            events = semantic_logger_events do
              logger.send(level) do
                {message: "hello world", payload: {user_id: 123}}
              end
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       {user_id: 123},
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "payload from block" do
            events = semantic_logger_events do
              logger.send(level) do
                {"test_key1" => "hello world", "test_key2" => "value2"}
              end
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       :nil,
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       {"test_key1" => "hello world", "test_key2" => "value2"},
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "message from hash does not modify hash" do
            details = {message: "hello world"}
            events  = semantic_logger_events do
              logger.send(level, details)
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       :nil,
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )

            assert_equal "hello world", details[:message]
          end

          it "message and explicit payload from hash does not modify hash" do
            details = {message: "hello world", payload: {user_id: 1230}}
            events  = semantic_logger_events do
              logger.send(level, details)
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       {user_id: 1230},
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )

            assert_equal "hello world", details[:message]
          end

          it "message and implied payload from hash does not modify hash" do
            details = {message: "hello world", user_id: 1230}
            events  = semantic_logger_events do
              logger.send(level, details)
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       {user_id: 1230},
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )

            assert_equal "hello world", details[:message]
            assert_equal 1230, details[:user_id]
          end

          it "message with explicit payload and duration" do
            events = semantic_logger_events do
              logger.send(level, "hello world", payload: {user_id: 1234}, duration: 20.7)
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      20.7,
              payload:       {user_id: 1234},
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "explicit payload and metric only" do
            events = semantic_logger_events do
              logger.send(level, payload: {user_id: 1234}, metric: "sidekiq.job.failed")
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       :nil,
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       {user_id: 1234},
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        "sidekiq.job.failed",
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "message with metric" do
            events = semantic_logger_events do
              logger.send(level, "hello world", metric: "sidekiq.job.failed")
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       :nil,
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        "sidekiq.job.failed",
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "metric only" do
            events = semantic_logger_events do
              logger.send(level, metric: "sidekiq.job.failed")
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       :nil,
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       :nil,
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        "sidekiq.job.failed",
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "message with metric and metric_amount" do
            events = semantic_logger_events do
              logger.send(level, "hello world", metric: "sidekiq.queue.latency", metric_amount: 2.5)
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       :nil,
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        "sidekiq.queue.latency",
              metric_amount: 2.5,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "message with implied duration" do
            events = semantic_logger_events do
              logger.send("measure_#{level}".to_sym, "hello world") { sleep 0.1 }
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      Numeric,
              payload:       :nil,
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "message with explicit duration" do
            events = semantic_logger_events do
              logger.send(level, "hello world", duration: 20.3)
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      20.3,
              payload:       :nil,
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "message with backtrace" do
            SemanticLogger.stub(:backtrace_level_index, 0) do
              events = semantic_logger_events do
                logger.send(level, "hello world", request_id: 1234)
              end

              assert_equal 1, events.size
              assert_semantic_logger_event(
                events.first,
                name:          "TestLogger",
                level:         level,
                level_index:   level_index,
                message:       "hello world",
                thread_name:   Thread.current.name,
                duration:      :nil,
                payload:       {request_id: 1234},
                exception:     :nil,
                backtrace:     Array,
                tags:          [],
                named_tags:    {},
                context:       :nil,
                metric:        :nil,
                metric_amount: :nil,
                dimensions:    :nil,
                time:          Time
              )
              assert events.first.backtrace.size.positive?, events.first.backtrace
            end
          end

          it "message with exception" do
            exc    = RuntimeError.new("Test")
            events = semantic_logger_events do
              logger.send(level, "hello world", exc)
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       :nil,
              exception:     exc,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "exception only" do
            exc    = RuntimeError.new("Test")
            events = semantic_logger_events do
              logger.send(level, exc)
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       :nil,
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       :nil,
              exception:     exc,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "message with backtrace and exception" do
            SemanticLogger.stub(:backtrace_level_index, 0) do
              exc    = RuntimeError.new("Test")
              events = semantic_logger_events do
                logger.send(level, "hello world", exc)
              end

              assert_equal 1, events.size
              assert_semantic_logger_event(
                events.first,
                name:          "TestLogger",
                level:         level,
                level_index:   level_index,
                message:       "hello world",
                thread_name:   Thread.current.name,
                duration:      :nil,
                payload:       :nil,
                exception:     exc,
                tags:          [],
                named_tags:    {},
                context:       :nil,
                metric:        :nil,
                metric_amount: :nil,
                dimensions:    :nil,
                time:          Time
              )
              assert events.first.backtrace
              assert events.first.backtrace.size.positive?, events.first.backtrace
            end
          end

          it "does not log when below min_duration" do
            events = semantic_logger_events do
              logger.send(level, "hello world", min_duration: 200, duration: 123.45, payload: {tracking_number: "123456", even: 2, more: "data"})
            end

            assert events.empty?
          end
        end

        describe "message as keyword argument" do
          it "message only" do
            events = semantic_logger_events do
              logger.send(level, message: "hello world")
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       :nil,
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "combines message from block" do
            events = semantic_logger_events do
              logger.send(level, message: "hello world") { "Calculations" }
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world -- Calculations",
              thread_name:   Thread.current.name,
              duration:      :nil,
              payload:       :nil,
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "message with explicit payload and duration" do
            events = semantic_logger_events do
              logger.send(level, message: "hello world", payload: {user_id: 1234}, duration: 20.7)
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      20.7,
              payload:       {user_id: 1234},
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "message with backtrace and exception" do
            SemanticLogger.stub(:backtrace_level_index, 0) do
              exc    = RuntimeError.new("Test")
              events = semantic_logger_events do
                logger.send(level, message: "hello world", exception: exc)
              end

              assert_equal 1, events.size
              assert_semantic_logger_event(
                events.first,
                name:          "TestLogger",
                level:         level,
                level_index:   level_index,
                message:       "hello world",
                thread_name:   Thread.current.name,
                duration:      :nil,
                payload:       :nil,
                exception:     exc,
                tags:          [],
                named_tags:    {},
                context:       :nil,
                metric:        :nil,
                metric_amount: :nil,
                dimensions:    :nil,
                time:          Time
              )
              assert events.first.backtrace
              assert events.first.backtrace.size.positive?, events.first.backtrace
            end
          end

          it "does not log when below min_duration" do
            events = semantic_logger_events do
              logger.send(level, message: "hello world", min_duration: 200, duration: 123.45, payload: {tracking_number: "123456", even: 2, more: "data"})
            end

            assert events.empty?
          end

          it "logs above min_duration" do
            events = semantic_logger_events do
              logger.send(level, message: "hello world", min_duration: 100, duration: 123.45, tracking_number: "123456", even: 2, more: "data")
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      123.45,
              payload:       {tracking_number: "123456", even: 2, more: "data"},
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end

          it "logs at min_duration" do
            events = semantic_logger_events do
              logger.send(level, message: "hello world", min_duration: 100, duration: 100.0, payload: {tracking_number: "123456", even: 2, more: "data"})
            end

            assert_equal 1, events.size
            assert_semantic_logger_event(
              events.first,
              name:          "TestLogger",
              level:         level,
              level_index:   level_index,
              message:       "hello world",
              thread_name:   Thread.current.name,
              duration:      100.0,
              payload:       {tracking_number: "123456", even: 2, more: "data"},
              exception:     :nil,
              tags:          [],
              named_tags:    {},
              context:       :nil,
              metric:        :nil,
              metric_amount: :nil,
              dimensions:    :nil,
              time:          Time
            )
          end
        end
      end
    end
  end
end
