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
  attr_accessor :index, :type, :client, :messages, :messages_mutex

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
  #   batch_size: [Fixnum]
  #     Size of list when sending to Elasticsearch. May be smaller if flush is triggered early.
  #     Default: 500
  #
  #   flush_interval: [Fixnum]
  #     Seconds to wait before attempting a flush to Elasticsearch. If no messages queued it's a NOOP.
  #     Default: 1
  #
  #   timeout_interval: [Fixnum]
  #     Seconds to allow the Elasticsearch client to flush the bulk message.
  #     Default: 10
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
  def initialize(options, &block)
    options       = options.dup

    @index        = options.delete(:index) || 'semantic_logger'
    @type         = options.delete(:type) || 'log'
    @flush_interval = options.delete(:flush_interval) || 1
    @timeout_interval = options.delete(:timeout_interval) || 10
    @batch_size     = options.delete(:batch_size) || 500
    @messages_mutex = Mutex.new
    @messages       = Array.new

    @url = options.delete(:url) || 'http://localhost:9200'

    reopen

    super(options, &block)
  end

  def reopen
    @client = Elasticsearch::Client.new(url: @url)

    @messages_mutex.synchronize do
      @messages = []
    end

    @flush_task = Concurrent::TimerTask.new(execution_interval: @flush_interval, timeout_interval: @timeout_interval) do |task|
      flush
    end.execute
  end

  def close
    @client.close
    @flush_task.shutdown
  end

  def call(log, logger)
    h = log.to_h(host, application)
    h.delete(:time)
    h[:timestamp] = log.time.utc.iso8601(SemanticLogger::Formatters::Base::PRECISION)
    h
  end

  def flush
    collected_messages = nil
    @messages_mutex.synchronize do
      if @messages.length > 0
        collected_messages = @messages
        @messages          = []
      end
    end

    if collected_messages
      bulk_result = @client.bulk(body: collected_messages)
      if bulk_result["errors"]
        failed = bulk_result["items"].select { |x| x["status"] != 201 }
        SemanticLogger::Processor.logger.error("ElasticSearch: Write failed. Messages discarded. : #{failed}")
      end
    end
  rescue Exception => exc
    SemanticLogger::Processor.logger.error('ElasticSearch: Failed to bulk insert log messages', exc)
  end

  # Log to the index for today
  def log(log)
    return false unless should_log?(log)

    daily_index = log.time.strftime("#{@index}-%Y.%m.%d")

    bulk_index = {'index' => { '_index' => daily_index, '_type' => @type } }
    bulk_payload = formatter.call(log, self)

    enqueue(bulk_index, bulk_payload)
  end

  def enqueue(bulk_index,bulk_payload)
    messages_len = 0

    @messages_mutex.synchronize do
      @messages.push(bulk_index)
      @messages.push(bulk_payload)

      messages_len = @messages.length
    end

    if messages_len >= @batch_size
      flush 
    end
  end

  # Deletes all log data captured for a day
  def delete_all(date = Date.today)
    delete(date.strftime(@request_path))
  end

end
