require 'socket'
module SemanticLogger
  module Appender
    # The Mongo Appender for the SemanticLogger
    # clarity_log Schema:
    #    _id        : ObjectId("4d9cbcbf7abb3abdaf9679cd"),
    #    time       : ISODate("2011-04-06T19:19:27.006Z"),
    #    host_name  : "Name of the host on which this log entry originated",
    #    application: 'Name of application or service logging the data - clarity_base, nginx, tomcat',
    #    pid        : process id
    #    thread     : "name of thread",
    #    name       : "ch.qos.logback.classic.db.mongo.MongoDBAppenderTest",
    #    level      : 'trace|debug|warn|info|error',
    #    message    : "blah blah",
    #    duration   : ms,  # Set by Logger#benchmark
    #    tags       : "Some tracking id" | ["id1", "id2"]
    #    payload : {
    #      Optional. Any user supplied data, including any thread specific context variables
    #      values supplied on a per log entry will override any thread context values
    #    }
    #    # When an exception is supplied as the first or second parameter
    #    # If supplied as the first parameter, message='exception name'
    #    exception: {
    #      name: 'MyException',
    #      description: 'blah',
    #      stack_trace: []
    #    }
    #
    #    # For trace and debug level logging, the following can also be logged
    #    # for all levels. Not on for higher levels due to performance impact
    #    source: {
    #      filename:
    #      method:
    #      line_number:
    #    }
    #
    # # Future, the Rails around filter can log the following additional data
    #   controller:
    #   action:
    #   duration: 'ms'
    #   http_verb: 'get|post|..'
    #   params: Hash
    #
    #   tracking_number: 'user defined tracking number'
    class MongoDB < SemanticLogger::Appender::Base
      attr_reader :db, :collection_name
      attr_accessor :host_name, :safe, :application

      # Create a MongoDB Appender instance
      #
      #   SemanticLogger::Appender::MongoDB.new(:db => Mongo::Connection.new['database'])
      #
      # Parameters:
      # :db [Mongo::Database]
      #   The MongoDB database connection to use, not the database name
      #
      # :collection_name [String]
      #   Name of the collection to store log data in
      #   Default: semantic_logger
      #
      # :host_name [String]
      #   host_name to include in the document logged to Mongo
      #   Default: first part of host name extracted from Socket
      #
      # :safe [Boolean]
      #   Whether to use safe write for logging
      #   Not recommended to change this value except to diagnose connection
      #   issues or when log entries are not being written to Mongo
      #   Default: false
      #
      # :application [String]
      #   Name of the application to include in the document written to mongo
      #   Default: nil (None)
      #
      # :collection_size [Integer]
      #   The size of the MongoDB capped collection to create in bytes
      #   Default: 1 GB
      #
      #   Some examples
      #     Prod: 25GB (.5GB per day across 4 servers over 10 days)
      #     Dev: .5GB
      #     Test: File
      #     Release: 4GB
      #
      #  :collection_max [Integer]
      #    Maximum number of log entries that the capped collection will hold
      #
      #  :level [Symbol]
      #    Only allow log entries of this level or higher to be written to MongoDB
      #
      def initialize(params={}, &block)
        @db              = params[:db] || raise('Missing mandatory parameter :db')
        @collection_name = params[:collection_name] || 'semantic_logger'
        @host_name       = params[:host_name] || Socket.gethostname.split('.').first
        @safe            = params[:safe] || false
        @application     = params[:application]

        # Create a collection that will hold the lesser of 1GB space or 10K documents
        @collection_size = params[:collection_size] || 1024**3
        @collection_max  = params[:collection_max]

        # Create the collection and necessary indexes
        create_indexes

        # Set the log level and formatter
        super(params[:level], &block)
      end

      # Create the required capped collection
      # Features of capped collection:
      # * No indexes by default (not even on _id)
      # * Documents cannot be deleted,
      # * Document updates cannot make them any larger
      # * Documents are always stored in insertion order
      #   * A find will always return the documents in their insertion order
      #
      # Creates an index based on tags to support faster lookups
      def create_indexes
        db.create_collection(collection_name, {:capped => true, :size => @collection_size, :max => @collection_max})
        collection.ensure_index('tags')
      end

      # Purge all data from the capped collection by dropping the collection
      # and recreating it.
      # Also useful when the size of the capped collection needs to be changed
      def purge_all
        collection.drop
        @collection = nil
        create_indexes
      end

      # Return the collection being used to write the log document to
      def collection
        @collection ||= db[collection_name]
      end

      # Flush all pending logs to disk.
      #  Waits for all sent documents to be written to disk
      def flush
        db.get_last_error
      end

      # Default log formatter
      #  Replace this formatter by supplying a Block to the initializer
      def default_formatter
        Proc.new do |log|
          document = {
            :time        => log.time,
            :host_name   => host_name,
            :pid         => $PID,
            :thread_name => log.thread_name,
            :name        => log.name,
            :level       => log.level,
          }
          document[:application] = application if application
          document[:message]     = self.class.strip_colorizing(log.message) if log.message
          document[:duration]    = log.duration if log.duration
          document[:tags]        = log.tags if log.tags && (log.tags.size > 0)

          if log.payload
            if log.payload.is_a?(Exception)
              exception = log.payload
              document[:payload] = {
                :exception => exception.class.name,
                :message   => exception.message,
                :backtrace => exception.backtrace
              }
            else
              document[:payload] = log.payload
            end
          end
          document
        end
      end

      # Strip the standard Rails colorizing from the logged message
      def self.strip_colorizing(message)
        message.to_s.gsub(/(\e(\[([\d;]*[mz]?))?)?/, '').strip
      end

      # Default host_name to use if none is supplied to the appenders initializer
      def self.host_name
        @@host_name ||= Socket.gethostname.split('.').first
      end

      # Override the default host_name
      def self.host_name=(host_name)
        @@host_name = host_name
      end

      # Log the message to MongoDB
      def log(log)
        # Insert log entry into Mongo
        # Use safe=>false so that we do not wait for it to be written to disk, or
        # for the response from the MongoDB server
        collection.insert(formatter.call(log), :safe=>safe) if level_index <= (log.level_index || 0)
      end

    end
  end
end