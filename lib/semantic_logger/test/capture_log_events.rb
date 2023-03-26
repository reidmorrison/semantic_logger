module SemanticLogger
  module Test
    # Logging class to captures all logging events in memory.
    #
    # Example:
    #
    # class UserTest < ActiveSupport::TestCase
    #   describe User do
    #     let(:capture_logger) { SemanticLogger::Test::CaptureLogEvents.new }
    #     let(:user) { User.new }
    #
    #     it "logs message" do
    #       user.stub(:logger, capture_logger) do
    #         user.enable!
    #       end
    #       assert_equal "Hello World", capture_logger.events.last.message
    #       assert_equal :info, capture_logger.events.last.level
    #     end
    #   end
    # end
    class CaptureLogEvents < SemanticLogger::Subscriber
      attr_accessor :events

      # By default collect all log levels, and collect metric only log events.
      def initialize(level: :trace, metrics: true)
        super(level: level, metrics: true)
        @events = []
      end

      def log(log)
        @events << log
      end

      def clear
        @events.clear
      end
    end
  end
end
