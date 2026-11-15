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
        super
        @events  = []
        @created = ObjectSpace::WeakMap.new
      end

      # Standing in for a logger, it runs the `on_log` subscribers for the log events it created, as a
      # logger does. Log events from a logger, received as the processor or an appender, already
      # went through them.
      def log(log)
        Logger.call_subscribers(log) if @created.key?(log)
        @events << log
      end

      # Supports batching of log events
      def batch(logs)
        logs.each { |log| self.log(log) }
      end

      def clear
        @events.clear
      end

      def to_h
        events.map(&:to_h)
      end

      private

      # Remember each log event created while standing in for a logger.
      def new_log(...)
        log = super
        @created[log] = true
        log
      end

      # Without a level of its own, follow the global default level the way a logger does,
      # so that `SemanticLogger.silence` applies.
      def fallback_level_index
        SemanticLogger.default_level_index
      end
    end
  end
end
