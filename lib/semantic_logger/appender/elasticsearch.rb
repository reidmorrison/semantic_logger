begin
  require 'elasticsearch'
rescue LoadError
  raise 'Gem elasticsearch is required for logging to Elasticsearch. Please add the gem "elasticsearch" to your Gemfile.'
end

require 'date'

# Forward all log messages to Elasticsearch.
#
# Example:
#
#   SemanticLogger.add_appender(
#     appender: :elasticsearch,
#     url:      'http://localhost:9200'
#   )
class SemanticLogger::Appender::Elasticsearch < SemanticLogger::Subscriber
  attr_accessor :url, :index, :type, :client, :flush_interval, :timeout_interval, :batch_size

  # Create Elasticsearch appender over persistent HTTP(S)
  #
  # Parameters:
  #   url: [String]
  #     Fully qualified address to the Elasticsearch service.
  #     Default: 'http://localhost:9200'
  #
  #   index: [String]
  #     Prefix of the index to store the logs in Elasticsearch.
  #     The final index appends the date so that indexes are used per day.
  #       I.e. The final index will look like 'semantic_logger-YYYY.MM.DD'
  #     Default: 'semantic_logger'
  #
  #   type: [String]
  #     Document type to associate with logs when they are written.
  #     Default: 'log'
  #
  #   level: [:trace | :debug | :info | :warn | :error | :fatal]
  #     Override the log level for this appender.
  #     Default: SemanticLogger.default_level
  #
  #   formatter: [Object|Proc|Symbol|Hash]
  #     An instance of a class that implements #call, or a Proc to be used to format
  #     the output from this appender
  #     Default: :raw_json (See: #call)
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
  def initialize(url: 'http://localhost:9200',
                 index: 'semantic_logger',
                 type: 'log',
                 level: nil,
                 formatter: nil,
                 filter: nil,
                 application: nil,
                 host: nil,
                 &block)

    @url   = url
    @index = index
    @type  = type

    super(level: level, formatter: formatter, filter: filter, application: application, host: host, &block)
    reopen
  end

  def reopen
    @client = Elasticsearch::Client.new(url: url, logger: SemanticLogger::Processor.logger.clone)
  end

  # Log to the index for today
  def log(log)
    bulk_payload = formatter.call(log, self)
    write_to_elasticsearch([bulk_index(log), bulk_payload])
    true
  end

  def batch(logs)
    messages = []
    day      = nil
    logs.each do |log|
      # Only write the bulk index once per day per batch. Supports mixed dates in a batch.
      if log.day != day
        messages << bulk_index(log)
        day = log.time.day
      end
      messages << formatter.call(log, self)
    end

    write_to_elasticsearch(messages)
    true
  end

  private

  def write_to_elasticsearch(messages)
    bulk_result = @client.bulk(body: messages)
    if bulk_result["errors"]
      failed = bulk_result["items"].select { |x| x["status"] != 201 }
      SemanticLogger::Processor.logger.error("ElasticSearch: Write failed. Messages discarded. : #{failed}")
    end
  end

  def bulk_index(log)
    daily_index = log.time.strftime("#{index}-%Y.%m.%d")
    {'index' => {'_index' => daily_index, '_type' => type}}
  end

  def default_formatter
    SemanticLogger::Formatters::Raw.new(time_format: :iso_8601, time_key: :timestamp)
  end

end
