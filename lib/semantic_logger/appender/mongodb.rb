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
    #    tracking_number : "Some tracking id"
    #    metadata : {
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
    class MongoDB
      attr_reader :db, :collection_name
      attr_accessor :formatter, :host_name, :safe, :application

      # Create a MongoDB Appender instance
      # SemanticLogger::Appender::MongoDB.new(
      #         :db => Cache::Work.db
      #        )
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
      def initialize(params={}, &block)
        @db              = params[:db] || raise('Missing mandatory parameter :db')
        @collection_name = params[:collection_name] || 'semantic_logger'
        @host_name       = params[:host_name] || Socket.gethostname.split('.').first
        @safe            = params[:safe] || false
        @application     = params[:application]

        # Create a collection that will hold the lesser of 1GB space or 10K documents
        @collection_size = params[:collection_size] || 1024**3
        @collection_max  = params[:collection_max]

        # Set the formatter to the supplied block
        @formatter       = block || self.default_formatter

        # Create the collection and necessary indexes
        create_indexes
      end

      # Create the required capped collection
      # Features of capped collection:
      # * No indexes by default (not even on _id)
      # * Documents cannot be deleted,
      # * Document updates cannot make them any larger
      # * Documents are always stored in insertion order
      #   * A find will always return the documents in their insertion order
      def create_indexes
        db.create_collection(collection_name, {:capped => true, :size => @collection_size, :max => @collection_max})
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

      # For JRuby include the Thread name rather than its id
      if defined? Java
        def self.thread_name
          Java::java.lang::Thread.current_thread.name
        end
      else
        def self.thread_name
          Thread.object_id
        end
      end

      # Default log formatter
      #  Replace this formatter by supplying a Block to the initializer
      def default_formatter
        Proc.new do |level, name, message, hash, block|
          document = {
            :time      => Time.now,
            :host_name => host_name,
            :pid       => $PID,
            :thread    => SemanticLogger::Appender::MongoDB.thread_name,
            :name      => name,
            :level     => level,
          }
          document[:application] = application if application
          document[:message] = self.class.strip_colorizing(message) if message

          SemanticLogger::Appender::MongoDB.populate(document, hash) if hash
          SemanticLogger::Appender::MongoDB.populate(document, block.call) if block
          document
        end
      end

      # Strip the standard Rails colorizing from the logged message
      def self.strip_colorizing(message)
        message.to_s.gsub(/(\e(\[([\d;]*[mz]?))?)?/, '').strip
      end

      # Log the message
      def log(level, name, message, hash, &block)
        # Insert log entry into Mongo
        # Use safe=>false so that we do not wait for it to be written to disk, or
        # for the response from the MongoDB server
        document = formatter.call(level, name, message, hash, &block)
        collection.insert(document, :safe=>safe)
      end

      # Populate Log Hash
      def self.populate(document, message)
        case message
        when ::String
          if document[:message]
            document[:message] << " " << strip_colorizing(message)
          else
            document[:message] = strip_colorizing(message)
          end
        when ::Exception
          document[:exception] = {
            :class => message.class.name,
            :message => message.message,
            :backtrace => message.backtrace
          }
        when ::Hash
          # With a hash, the message can be an element of the hash itself
          if msg = message[:message]
            # Cannot change supplied hash
            hash = message.clone
            hash.delete(:message)
            if document[:message]
              document[:message] << " " << strip_colorizing(msg)
            else
              document[:message] = strip_colorizing(msg)
            end
            document[:metadata] = hash
          else
            document[:metadata] = message
          end
        else
          if document[:message]
            document[:message] << " " << msg.inspect
          else
            document[:message] = msg.inspect
          end
        end
        document
      end

    end
  end
end