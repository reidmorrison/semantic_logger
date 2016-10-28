begin
  require 'redis'
  require 'json'
  require 'time'
rescue LoadError
  raise 'Gem redis is required for logging to Redis. Please add the gem "redis" to your Gemfile.'
end

module SemanticLogger
  module Appender
    # The Redis Appender for the SemanticLogger
    # Each level represents a topic that is published to
    #
    # Parameters
    #  :db
    #     Redis db connection
    #
    # Example:
    #   require 'semantic_logger'
    #
    #   client   = Redis.new
    #
    #   appender = SemanticLogger::Appender::Redis.new(
    #     db:              client,
    #   )
    #   SemanticLogger.add_appender(appender: appender)
    #
    #   logger = SemanticLogger['Example']
    #
    #   # Log some messages
    #   logger.info 'This message is written to a Redis list as a json string
    #   under the 'info' key'
    class Redis < SemanticLogger::Subscriber
      attr_reader :db

      # Create a Redis Appender instance
      #
      # Parameters:
      #   db: [Redis]
      #     The Redis database connection to use
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: SemanticLogger.default_level
      #
      #   formatter: [Object|Proc|Symbol]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: Use the built-in formatter (See: #call)
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      #
      #   host: [String]
      #     Name of this host to appear in log messages.
      #     Default: SemanticLogger.host
      #
      #   application: [String]
      #     Name of this application to appear in log messages.
      #     Default: SemanticLogger.application
      def initialize(options = {}, &block)
        options          = options.dup
        @db              = options.delete(:db) || raise('Missing mandatory parameter :db')

        # Set the log level and formatter
        super(options, &block)
        reopen
      end

      # After forking an active process call #reopen to re-open
      # open the handles to resources
      def reopen
        # nothing to do
      end

      # Flush all pending logs to disk.
      #  Waits for all sent documents to be written to disk
      def flush
        # nothing to do
      end

      def purge_all
        @db.flushdb
      end

      # Log the message to MongoDB
      def log(log)
        return false unless should_log?(log)

        # Insert log entry into Redis
        @db.publish log.level.to_s, formatter.call(log, self)
        true
      end

      private

      def default_formatter
        SemanticLogger::Formatters::Json.new
      end
    end
  end
end
