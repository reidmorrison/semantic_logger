module SemanticLogger
  module Test
    # Logging class to captures all logging events in memory.
    #
    # Example:
    #
    #   class UserTest < ActiveSupport::TestCase
    #     describe User do
    #       let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }
    #       let(:user) { User.new }
    #
    #       it "logs message" do
    #         user.stub(:logger, logger) do
    #           user.enable!
    #         end
    #         assert log = logger.events.first
    #         assert_equal "Hello World", log.message
    #         assert_equal :info, log.level
    #       end
    #     end
    #   end
    class CaptureLogEvents < SemanticLogger::Subscriber
      attr_accessor :events

      # By default collect all log levels, and collect metric only log events.
      def initialize(level: :trace, metrics: true)
        super(level: level, metrics: true)
        @events = []
      end

      def log(log)
        Logger.call_subscribers(log)
        @events << log
      end

      # Supports batching of log events
      def batch(logs)
        @events += log
      end

      def clear
        @events.clear
      end

      # Support silencing of log messages
      def level_index
        @level_index || SemanticLogger.default_level_index
      end

      def to_h
        events.map(&:to_h)
      end
    end
  end
end
