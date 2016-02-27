require 'date'
# Forward all log messages to Elasticsearch.
#
# Example:
#   SemanticLogger.add_appender(
#     appender: :elasticsearch,
#     url:      'http://localhost:9200'
#   )
class SemanticLogger::Appender::Elasticsearch < SemanticLogger::Appender::Http
  attr_accessor :index, :type

  # Create Elasticsearch appender over persistent HTTP(S)
  #
  # Parameters:
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
  def initialize(options, &block)
    options       = options.dup
    @index        = options.delete(:index) || 'semantic_logger'
    @type         = options.delete(:type) || 'log'
    options[:url] ||= 'http://localhost:9200'

    super(options, &block)
  end

  # Log to the index for today
  def log(log)
    return false if (level_index > (log.level_index || 0)) ||
      !include_message?(log) # Filtered out?

    post(formatter.call(log, self), "#{index}-#{log.time.strftime('%Y.%m.%d')}/#{type}")
  end

  # Deletes all log data captured for a day
  def delete_all(date = Date.today)
    "#{index}-#{date.strftime('%Y.%m.%d')}/#{type}"
  end

end
