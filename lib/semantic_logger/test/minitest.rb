module SemanticLogger
  module Test
    module Minitest
      # Returns [Array<SemanticLogger::Log>] the log events from Semantic Logger
      # captured whilst executing the supplied block.
      #
      # Notes:
      # - All log messages are returned regardless of the global default log level.
      def semantic_logger_events(deprecated_klass = nil, klass: deprecated_klass, silence: :trace, &block)
        logger = SemanticLogger::Test::CaptureLogEvents.new
        if klass
          klass.stub(:logger, logger, &block)
        elsif silence
          SemanticLogger.silence(silence) do
            SemanticLogger::Logger.stub(:processor, logger, &block)
          end
        else
          SemanticLogger::Logger.stub(:processor, logger, &block)
        end
        logger.events
      end

      # Returns [Array<SemanticLogger::Test::MetricEvent>] the metric calls (`increment`, `time`, and
      # `record`) captured whilst executing the supplied block, as they were made, before they are
      # aggregated, whether or not a metric appender is present.
      #
      #   metrics = semantic_logger_metrics { Signup.new.call(user) }
      #   assert_metric(metrics, name: "users.signup", kind: :counter, value: 1)
      #
      # Pass `klass:` to capture only the metric calls made through that class's logger.
      def semantic_logger_metrics(klass: nil, &)
        logger = SemanticLogger::Test::CaptureLogEvents.new
        if klass
          klass.stub(:logger, logger, &)
        else
          SemanticLogger::Logger.stub(:processor, logger, &)
        end
        logger.metric_events
      end

      # Verify that one of the captured metric calls has all the given attributes, and return it.
      #
      #   metrics = semantic_logger_metrics { Signup.new.call(user) }
      #   assert_metric(metrics, name: "users.signup", kind: :counter, value: 1)
      #   assert_metric(metrics, name: "supplier.add_user", kind: :histogram, unit: "s", value: Float)
      #
      # metrics: [Array<SemanticLogger::Test::MetricEvent>|SemanticLogger::Test::MetricEvent]
      #   The metric calls captured, such as by #semantic_logger_metrics, or one of them.
      #
      # An expected value may be :nil, a Class, a Range, a Regexp, or any value to compare with (see
      # SemanticLogger::Test::MetricEvent#matches?). An attribute that is not given is not checked.
      def assert_metric(metrics, name:, kind: nil, value: nil, unit: nil, dimensions: nil)
        metrics  = Array(metrics)
        expected = {name: name, kind: kind, value: value, unit: unit, dimensions: dimensions}.compact
        metric   = metrics.find { |captured| captured.matches?(**expected) }

        failure = lambda do
          captured = metrics.map { |captured_metric| "  #{captured_metric.to_h.inspect}" }
          "No metric matching #{expected.inspect} was captured. Captured #{metrics.size} metric(s):\n" \
            "#{captured.join("\n")}"
        end

        assert metric, failure # rubocop:disable Minitest/AssertWithExpectedArgument -- the message, as a Proc
        metric
      end

      # Verify a single log event has all the required attributes.
      def assert_semantic_logger_event(event, level: nil, name: nil, message: nil, message_includes: nil,
                                       payload: nil, payload_includes: nil,
                                       exception: nil, exception_includes: nil, backtrace: nil, call_site: nil,
                                       thread_name: nil, tags: nil, named_tags: nil, context: nil,
                                       level_index: nil, duration: nil, time: nil,
                                       metric: nil, metric_amount: nil, dimensions: nil)
        assert event, "No log event occurred"

        assert_semantic_logger_entry(event, :message, message)
        assert_semantic_logger_entry(event, :name, name)
        assert_semantic_logger_entry(event, :level, level)
        assert_semantic_logger_entry(event, :thread_name, thread_name)
        assert_semantic_logger_entry(event, :tags, tags)
        assert_semantic_logger_entry(event, :named_tags, named_tags)
        assert_semantic_logger_entry(event, :context, context)
        assert_semantic_logger_entry(event, :metric, metric)
        assert_semantic_logger_entry(event, :metric_amount, metric_amount)
        assert_semantic_logger_entry(event, :dimensions, dimensions)
        assert_semantic_logger_entry(event, :level_index, level_index)
        assert_semantic_logger_entry(event, :duration, duration)
        assert_semantic_logger_entry(event, :time, time)
        assert_semantic_logger_entry(event, :exception, exception)
        assert_semantic_logger_entry(event, :backtrace, backtrace)
        assert_semantic_logger_entry(event, :call_site, call_site)
        assert_semantic_logger_entry(event, :payload, payload)

        if message_includes
          assert_includes(
            event.message,
            message_includes,
            -> { "Expected message to include '#{message_includes}' in log event #{event.inspect}" }
          )
        end

        if payload_includes
          payload_includes.each_pair do |key, expected|
            actual = event.payload[key]

            assert_semantic_logger_entry(event, "payload #{key}", expected, actual)
          end
        end

        return unless exception_includes

        exception_includes.each_pair do |key, expected|
          actual = event.exception.send(key)

          assert_semantic_logger_entry(event, "exception #{key}", expected, actual)
        end
      end

      private

      def assert_semantic_logger_entry(event, name, expected, actual = event.send(name))
        return if expected.nil?

        case expected
        when :nil

          assert_nil actual, "Expected nil #{name} for log event: #{event.to_h.inspect}"
        when Class

          assert_kind_of expected, actual, lambda {
            "Type #{expected} expected for #{name} in log event: #{event.to_h.inspect}"
          }
        else
          assert_equal expected, actual, "Mismatched #{name} for log event: #{event.to_h.inspect}"
        end
      end
    end
  end
end
