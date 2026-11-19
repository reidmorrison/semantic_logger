require "socket"
begin
  require "mongo"
rescue LoadError
  raise LoadError,
        'Gem mongo is required for logging to MongoDB. Please add the gem "mongo" v2.0 or greater to your Gemfile.'
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
    #   appender = SemanticLogger::Appender::MongoDB.new(
    #     uri:             'mongodb://127.0.0.1:27017/test',
    #     collection_size: 1024**3 # 1.gigabyte
    #   )
    #   SemanticLogger.add_appender(appender: appender)
    #
    #   logger = SemanticLogger['Example']
    #
    #   # Log some messages
    #   logger.info 'This message is written to mongo as a document'
    class MongoDB < SemanticLogger::Subscriber
      attr_reader :client, :collection

      # Create a MongoDB Appender instance
      #
      # Parameters:
      #   uri: [String]
      #     Mongo connection string.
      #     Example:
      #       mongodb://127.0.0.1:27017/test
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
      #     Default: no max limit
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: none (:trace), so it writes every entry that a logger emits; each logger
      #     filters by its own level.
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
      def initialize(uri:,
                     collection_name: "semantic_logger",
                     write_concern: 0,
                     collection_size: 1024**3,
                     collection_max: nil,
                     **args,
                     &)
        @client          = Mongo::Client.new(uri, logger: logger)
        @collection_name = collection_name
        @options         = {
          capped: true,
          size:   collection_size,
          write:  {w: write_concern}
        }
        @options[:max] = collection_max if collection_max

        reopen

        # Create the collection and necessary indexes
        create_indexes

        super(**args, &)
      end

      # After forking an active process call #reopen to re-open
      # open the handles to resources
      def reopen
        @collection = client[@collection_name, @options]
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
        # Create Capped collection
        begin
          @collection.create
        rescue Mongo::Error::OperationFailure
          nil
        end

        @collection.indexes.create_one(tags: 1)
      end

      # Purge all data from the capped collection by dropping the collection
      # and recreating it.
      # Also useful when the size of the capped collection needs to be changed
      def purge_all
        collection.drop
        reopen
        create_indexes
      end

      # Log the message to MongoDB
      #
      # BSON stores only valid UTF-8 text, and keys without NUL bytes. A document that holds other
      # text, such as a binary response body in the payload, or an exception message that quotes
      # invalid input, is stored as a copy that BSON accepts (see #storable). Only such a document is
      # copied: BSON checks the text as it serializes the document, before anything is sent.
      def log(log)
        document = format_log(log)
        begin
          collection.insert_one(document)
        rescue *TEXT_ERRORS
          collection.insert_one(storable(document))
        end
        true
      end

      # Errors raised for a document that cannot be stored, which retrying cannot insert either.
      # BSON raises BSON::Error, ArgumentError (a NUL byte in text that it writes as a C string, such
      # as a Regexp's source; the copy #log stores removes them from keys), or RangeError (an Integer too large
      # for 64 bits) while the document is serialized, before anything is sent, and the driver raises
      # Mongo::Error::MaxBSONSize for a document larger than the server accepts. A document whose text
      # is at fault (TEXT_ERRORS) is first tried again as a copy that BSON accepts.
      DOCUMENT_ERRORS = [BSON::Error, ArgumentError, RangeError, Mongo::Error::MaxBSONSize].freeze

      # Errors BSON raises for text it cannot store: EncodingError for text that is not valid UTF-8 or
      # cannot be converted to it, and ArgumentError for a NUL byte in text that it writes as a C
      # string, such as a key. The copy cannot fix every such text, such as a Regexp's source, which
      # then raises again.
      TEXT_ERRORS = [EncodingError, ArgumentError].freeze

      # Except BSON::Error::BSONDecodeError, which comes from reading the server's reply rather than
      # from the document, so it is treated like any other error from the server: the thread backs
      # off.
      def message_error?(exception)
        return false if exception.is_a?(BSON::Error::BSONDecodeError)

        super || DOCUMENT_ERRORS.any? { |error| exception.is_a?(error) }
      end

      # Only the collection name: the uri can hold a user and password. See Subscriber#inspect.
      def inspect_details
        "collection=#{@collection_name.inspect}"
      end

      private

      def default_formatter
        SemanticLogger::Formatters::Raw.new
      end

      # Returns a copy of the document that BSON can store: every String and Symbol converted to
      # valid UTF-8 (see Utils.encode_utf8), and the NUL bytes removed from every key, which BSON
      # writes as a C string. Binary text is read as the UTF-8 it usually holds, and invalid bytes
      # are dropped, as the JSON formatters write them. Any other value is kept as it is, for BSON
      # to store in its own type.
      #
      # So that the copy is bounded, a Hash or Array nested too deeply, or that holds itself, is
      # replaced where it is too deep or repeats, as the JSON formatters replace it (see
      # Utils.bounded_structure). Only a document whose text BSON refuses before it reaches a
      # structure that holds itself gets here: BSON's own serializer overflows the stack at one.
      def storable(value, depth = 0, ancestors = nil)
        return Utils.encode_utf8(value) unless value.is_a?(Hash) || value.is_a?(Array)

        Utils.bounded_structure(value, depth, ancestors) { |level, seen| storable_members(value, level, seen) }
      end

      # Returns a copy of the members of a Hash or Array, each made storable (see #storable).
      def storable_members(value, depth, ancestors)
        if value.is_a?(Hash)
          value.each_with_object({}) { |(key, val), hash| hash[storable_key(key)] = storable(val, depth, ancestors) }
        else
          value.map { |element| storable(element, depth, ancestors) }
        end
      end

      # Returns the key, converted to valid UTF-8 and without NUL bytes (see #storable). A key other
      # than a String or Symbol is kept as it is, for BSON to write as it writes the original key,
      # such as an Integer as its digits, or to refuse, such as a Hash.
      def storable_key(key)
        return key unless key.is_a?(String) || key.is_a?(Symbol)

        key  = Utils.encode_utf8(key)
        text = key.is_a?(Symbol) ? key.name : key
        return key unless text.include?("\0")

        key.is_a?(Symbol) ? text.delete("\0").to_sym : text.delete("\0")
      end
    end
  end
end
