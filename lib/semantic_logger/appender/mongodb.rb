require 'socket'
begin
  require 'mongo'
rescue LoadError
  raise 'Gem mongo is required for logging to MongoDB. Please add the gem "mongo" to your Gemfile.'
end

module SemanticLogger
  module Appender
    # The Mongo Appender for the SemanticLogger
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
    #   SemanticLogger.add_appender(appender)
    #
    #   logger = SemanticLogger['Example']
    #
    #   # Log some messages
    #   logger.info 'This message is written to mongo as a document'
    class MongoDB < SemanticLogger::Appender::Base
      attr_reader :db, :collection_name, :collection
      attr_accessor :host, :write_concern, :application

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
      #   host: [String]
      #     host name to include in the document logged to Mongo
      #     Default: SemanticLogger.host_name
      #
      #   application: [String]
      #     Name of the application to include in the document written to mongo
      #     Default: nil (None)
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
      #   formatter: [Object|Proc]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: Use the built-in formatter (See: #call)
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      def initialize(options = {}, &block)
        options             = options.dup
        @db                 = options.delete(:db) || raise('Missing mandatory parameter :db')
        @collection_name    = options.delete(:collection_name) || 'semantic_logger'
        @host               = options.delete(:host) || options.delete(:host_name) || SemanticLogger.host
        @write_concern      = options.delete(:write_concern) || 0
        @application        = options.delete(:application) || SemanticLogger.application

        # Create a collection that will hold the lesser of 1GB space or 10K documents
        @collection_size    = options.delete(:collection_size) || 1024**3
        @collection_max     = options.delete(:collection_max)

        reopen

        # Create the collection and necessary indexes
        create_indexes

        # Set the log level and formatter
        super(options, &block)
      end

      # After forking an active process call #reopen to re-open
      # open the handles to resources
      def reopen
        @collection = db[@collection_name]
      end

      # Create the required capped collection.
      #
      # Features of capped collection:
      # * No indexes by default (not even on _id)
      # * Documents cannot be deleted,
      # * Document updates cannot make them any larger
      # * Documents are always stored in insertion order
      #   * A find will always return the documents in their insertion order
      #
      # Creates an index based on tags to support faster searches.
      def create_indexes
        options       = {capped: true, size: @collection_size}
        options[:max] = @collection_max if @collection_max
        db.create_collection(collection_name, options)
        db[@collection_name].ensure_index('tags')
      end

      # Purge all data from the capped collection by dropping the collection
      # and recreating it.
      # Also useful when the size of the capped collection needs to be changed
      def purge_all
        collection.drop
        @collection = nil
        create_indexes
      end

      # Flush all pending logs to disk.
      #  Waits for all sent documents to be written to disk
      def flush
        db.get_last_error
      end

      # Default log formatter
      #  Replace this formatter by supplying a Block to the initializer
      def call(log, logger)
        h               = log.to_h
        h[:host]        = host
        h[:application] = application
        h
      end

      # Log the message to MongoDB
      def log(log)
        # Ensure minimum log level is met, and check filter
        return false if (level_index > (log.level_index || 0)) || !include_message?(log)

        # Insert log entry into Mongo
        collection.insert(formatter.call(log, self), w: @write_concern)
        true
      end

    end
  end
end
