begin
  require 'redis'
  require 'json'
rescue LoadError
  raise 'Gem redis is required for logging to Redis. Please add the gem "redis" to your Gemfile.'
end

module SemanticLogger
  module Appender
    # The Redis Appender for the SemanticLogger
    #
    # Mongo Document Schema:
    #    _id:         ObjectId("4d9cbcbf7abb3abdaf9679cd"),
    #    time:        ISODate("2011-04-06T19:19:27.006Z"),
    #    host:        'Name of the host on which this log entry originated',
    #    application  'Name of application or service logging the data - clarity_base, nginx, tomcat',
    #    pid:         process id
    #    thread:      "name or id of thread",
    #    name:        "com.clarity.MyClass",
    #    level:       'trace|debug|info|warn|error|fatal'
    #    level_index: 0|1|2|3|4|5
    #    message:     "Message supplied to the logging call",
    #    duration:    'human readable duration',
    #    duration_ms: ms,
    #    tags:        ["id1", "id2"]
    #    exception: {
    #      name:        'MyException',
    #      message:     'Invalid value',
    #      stack_trace: []
    #    }
    #    # When a backtrace is captured
    #    file_name:   'my_class.rb'
    #    line_number: 42
    #
    # Example:
    #   require 'semantic_logger'
    #
    #   client   = Mongo::MongoClient.new
    #   database = client['test']
    #
    #   appender = SemanticLogger::Appender::MongoDB.new(
    #     db:              database,
    #     collection_size: 1024**3 # 1.gigabyte
    #   )
    #   SemanticLogger.add_appender(appender: appender)
    #
    #   logger = SemanticLogger['Example']
    #
    #   # Log some messages
    #   logger.info 'This message is written to mongo as a document'
    class Redis < SemanticLogger::Subscriber
      attr_reader :db, :max_logs

      # Create a MongoDB Appender instance
      #
      # Parameters:
      #   db: [Mongo::Database]
      #     The MongoDB database connection to use, not the database name
      #
      #   collection_name: [String]
      #     Name of the collection to store log data in
      #     Default: semantic_logger
      #
      #   write_concern: [Integer]
      #     Write concern to use
      #     see: http://docs.mongodb.org/manual/reference/write-concern/
      #     Default: 0
      #
      #   collection_size: [Integer]
      #     The size of the MongoDB capped collection to create in bytes
      #     Default: 1 GB
      #     Examples:
      #       Prod: 25GB (.5GB per day across 4 servers over 10 days)
      #       Dev: .5GB
      #       Test: File
      #       Release: 4GB
      #
      #   collection_max: [Integer]
      #     Maximum number of log entries that the capped collection will hold.
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
        @max_logs = options.delete(:max_logs) || 5000

        # Set the log level and formatter
        super(options, &block)
        reopen
      end

      # After forking an active process call #reopen to re-open
      # open the handles to resources
      def reopen
        #@collection = db[@collection_name]
      end

      # Flush all pending logs to disk.
      #  Waits for all sent documents to be written to disk
      def flush
        #db.get_last_error
      end

      def purge_all
        @db.flushdb
      end

      # Log the message to MongoDB
      def log(log)
        return false unless should_log?(log)

        # Insert log entry into Mongo
        
        @db.rpush log.level.to_s, formatter.call(log, self)
        true
      end

      private

      def default_formatter
        SemanticLogger::Formatters::Json.new
      end
    end
  end
end
