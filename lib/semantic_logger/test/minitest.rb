module SemanticLogger
  module Test
    module Minitest
      # Returns [Array<SemanticLogger::Log>] the log events from Semantic Logger
      # captured whilst executing the supplied block.
      def semantic_logger_events(klass = nil, &block)
        logger = SemanticLogger::Test::CaptureLogEvents.new
        if klass
          klass.stub(:logger, logger, &block)
        else
          SemanticLogger.silence(:trace) do
            SemanticLogger::Logger.stub(:processor, logger, &block)
          end
        end
        logger.events
      end

      # Verify a single log event has all the required attributes.
      def assert_semantic_logger_event(event, level: nil, name: nil, message: nil, message_includes: nil,
                                       payload: nil, payload_includes: nil,
                                       thread_name: nil, tags: nil, named_tags: nil, context: nil,
                                       metric: nil, metric_amount: nil, dimensions: nil)
        msg = message || message_includes || "no message"
        assert event, "Log event missing for message: '#{msg}'"
        assert_equal message, event.message if message
        assert_includes event.message, message_includes if message_includes
        assert_equal name, event.name, -> { "Mismatched log name for message: '#{msg}'" } if name
        assert_equal level, event.level, -> { "Mismatched log level for message: '#{msg}'" } if level

        if payload_includes
          payload_includes.each_pair do |key, expected_value|
            value = event.payload[key]
            if expected_value.nil?
              assert_nil value, -> { "Mismatched key: #{key.inspect} in log payload: #{event.payload} for message: '#{msg}'" }
            else
              assert_equal expected_value, value, -> { "Mismatched key: #{key.inspect} in log payload: #{event.payload} for message: '#{msg}'" }
            end
          end
        elsif payload
          assert_equal payload, event.payload, -> { "Mismatched log payload: #{event.payload} for message: '#{msg}'" }
        end

        assert_equal thread_name, event.thread_name, -> { "Mismatched thread_name for message: '#{msg}'" } if thread_name
        assert_equal tags, event.tags, -> { "Mismatched tags for message: '#{msg}'" } if tags
        assert_equal named_tags, event.named_tags, -> { "Mismatched named_tags for message: '#{msg}'" } if named_tags
        assert_equal context, event.context, -> { "Mismatched context for message: '#{msg}'" } if context
        assert_equal metric, event.metric, -> { "Mismatched metric for message: '#{msg}'" } if metric
        assert_equal metric_amount, event.metric_amount, -> { "Mismatched metric_amount for message: '#{msg}'" } if metric_amount
        assert_equal dimensions, event.dimensions, -> { "Mismatched dimensions for message: '#{msg}'" } if dimensions
      end
    end
  end
end
