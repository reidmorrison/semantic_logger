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

      # Verify a single log event has all the required attributes.
      def assert_semantic_logger_event(event, level: nil, name: nil, message: nil, message_includes: nil,
                                       payload: nil, payload_includes: nil,
                                       exception: nil, exception_includes: nil, backtrace: nil,
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
            assert_semantic_logger_entry(event, "payload #{name}", expected, actual)
          end
        end

        if exception_includes
          payload_includes.each_pair do |key, expected|
            actual = event.exception.send(key)
            assert_semantic_logger_entry(event, "Exception #{name}", expected, actual)
          end
        end
      end

      private

      def assert_semantic_logger_entry(event, name, expected, actual = event.send(name))
        return if expected.nil?

        case expected
        when :nil
          assert_nil actual, "Expected nil #{name} for log event: #{event.to_h.inspect}"
        when Class
          assert actual.is_a?(expected), -> { "Type #{expected} expected for #{name} in log event: #{event.to_h.inspect}" }
        else
          assert_equal expected, actual, "Mismatched #{name} for log event: #{event.to_h.inspect}"
        end
      end
    end
  end
end
