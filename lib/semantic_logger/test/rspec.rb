require "rspec/expectations"

module SemanticLogger
  module Test
    # RSpec matchers and helpers for asserting on Semantic Logger events.
    #
    # These mirror the Minitest helpers in SemanticLogger::Test::Minitest.
    #
    # Enable them once, in spec_helper.rb:
    #
    #   require "semantic_logger/test/rspec"
    #
    #   RSpec.configure do |config|
    #     config.include SemanticLogger::Test::RSpec
    #   end
    #
    # Capture the events emitted whilst running a block, then assert on them:
    #
    #   events = capture_semantic_logger_events { User.new.enable! }
    #   expect(events.first).to be_a_semantic_logger_event(level: :info, message: "User enabled")
    #
    # Or assert directly that a block logs a matching event:
    #
    #   expect { User.new.enable! }.to(
    #     log_semantic_logger_event(level: :info, message: "User enabled")
    #   )
    module RSpec
      # Attributes that may be asserted on a single log event. The keys map
      # directly onto SemanticLogger::Log attributes, except for the
      # *_includes variants which assert a partial (substring / subset) match.
      EVENT_ATTRIBUTES = %i[
        level name message thread_name tags named_tags context
        metric metric_amount dimensions level_index duration time
        exception backtrace payload
      ].freeze

      # Matches a single SemanticLogger::Log against a set of expectations.
      #
      # An expected value may be:
      #   * a Class    - the actual value must be a kind_of that class
      #   * :nil       - the actual value must be nil
      #   * any value  - compared with ==
      class EventMatcher
        include ::RSpec::Matchers::Composable

        def initialize(message_includes: nil, payload_includes: nil, exception_includes: nil, **expected)
          unknown = expected.keys - EVENT_ATTRIBUTES
          raise ArgumentError, "Unknown log event attribute(s): #{unknown.join(', ')}" unless unknown.empty?

          @expected           = expected
          @message_includes   = message_includes
          @payload_includes   = payload_includes
          @exception_includes = exception_includes
        end

        def matches?(event)
          @event = event
          return failed("no log event") unless event

          @expected.each_pair do |name, expected|
            actual = event.public_send(name)
            return failed(mismatch(name, expected, actual)) unless attribute_matches?(expected, actual)
          end

          return failed(includes_failure(:message, @message_includes)) unless message_includes_matches?
          return failed(includes_failure(:payload, @payload_includes)) unless payload_includes_matches?
          return failed(includes_failure(:exception, @exception_includes)) unless exception_includes_matches?

          true
        end

        def description
          "be a semantic logger event matching #{full_expectations.inspect}"
        end

        def failure_message
          "expected log event to #{description}, but #{@failure}.\n" \
            "Log event: #{event_inspect}"
        end

        def failure_message_when_negated
          "expected log event not to #{description}.\nLog event: #{event_inspect}"
        end

        private

        def failed(reason)
          @failure = reason
          false
        end

        def attribute_matches?(expected, actual)
          case expected
          when :nil
            actual.nil?
          when Class
            actual.is_a?(expected)
          else
            expected == actual
          end
        end

        def message_includes_matches?
          return true unless @message_includes

          @event.message&.include?(@message_includes)
        end

        def payload_includes_matches?
          return true unless @payload_includes

          payload = @event.payload || {}
          @payload_includes.all? { |key, value| payload[key] == value }
        end

        def exception_includes_matches?
          return true unless @exception_includes

          exception = @event.exception
          return false unless exception

          @exception_includes.all? { |key, value| exception.public_send(key) == value }
        end

        def mismatch(name, expected, actual)
          "#{name} was #{actual.inspect} (expected #{expected.inspect})"
        end

        def includes_failure(name, expected)
          "#{name} did not include #{expected.inspect}"
        end

        def full_expectations
          @expected.merge(
            {
              message_includes:   @message_includes,
              payload_includes:   @payload_includes,
              exception_includes: @exception_includes
            }.compact
          )
        end

        def event_inspect
          @event.respond_to?(:to_h) ? @event.to_h.inspect : @event.inspect
        end
      end

      # Matches a block, asserting that it emits at least one log event that
      # matches the supplied expectations.
      class LogEventMatcher
        include ::RSpec::Matchers::Composable

        def initialize(capture, on:, expected:)
          @capture  = capture
          @on       = on
          @matcher  = EventMatcher.new(**expected)
        end

        def matches?(block)
          @events = @capture.call(@on, &block)
          @events.any? { |event| @matcher.matches?(event) }
        end

        def supports_block_expectations?
          true
        end

        def description
          "log a semantic logger event matching #{@matcher.description}"
        end

        def failure_message
          "expected the block to #{description}.\n" \
            "Captured #{@events.size} event(s):\n#{captured_inspect}"
        end

        def failure_message_when_negated
          "expected the block not to #{description}, but it did.\n" \
            "Captured #{@events.size} event(s):\n#{captured_inspect}"
        end

        private

        def captured_inspect
          @events.map { |event| "  #{event.to_h.inspect}" }.join("\n")
        end
      end

      # Returns [Array<SemanticLogger::Log>] the log events captured whilst
      # running the supplied block.
      #
      # Notes:
      # - All log events are captured regardless of the global default log level.
      # - Pass a class to capture only events logged through that class's logger.
      #   Otherwise every log event in the process is captured for the duration
      #   of the block.
      def capture_semantic_logger_events(klass = nil, silence: :trace, &block)
        logger = SemanticLogger::Test::CaptureLogEvents.new

        if klass
          allow(klass).to receive(:logger).and_return(logger)
          block.call
        elsif silence
          SemanticLogger.silence(silence) do
            stub_processor(logger, &block)
          end
        else
          stub_processor(logger, &block)
        end

        logger.events
      end

      # Matcher for a single captured log event.
      #
      #   expect(events.first).to be_a_semantic_logger_event(level: :info, message: "Hi")
      def be_a_semantic_logger_event(**expected)
        EventMatcher.new(**expected)
      end

      # Composable alias, for use inside other matchers:
      #
      #   expect(events).to include(a_semantic_logger_event(message: "Hi"))
      def a_semantic_logger_event(**expected)
        EventMatcher.new(**expected)
      end

      # Block matcher asserting that the block logs a matching event.
      #
      #   expect { User.new.enable! }.to(
      #     log_semantic_logger_event(level: :info, message: "User enabled")
      #   )
      #
      # Pass `on:` to capture only one class's events.
      def log_semantic_logger_event(on: nil, **expected)
        LogEventMatcher.new(method(:capture_semantic_logger_events), on: on, expected: expected)
      end

      private

      def stub_processor(logger)
        allow(SemanticLogger::Logger).to receive(:processor).and_return(logger)
        yield
      ensure
        allow(SemanticLogger::Logger).to receive(:processor).and_call_original
      end
    end
  end
end
