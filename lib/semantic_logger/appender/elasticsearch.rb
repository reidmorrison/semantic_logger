require 'date'
# Forward all log messages to Elasticsearch.
#
# Example:
#   appender = SemanticLogger::Appender::Elasticsearch.new(
#     url:   'http://localhost:9200'
#   )
#
#   # Optional: Exclude health_check log entries
#   appender.filter = Proc.new { |log| log.message !~ /(health_check|Not logged in)/}
#
#   SemanticLogger.add_appender(appender)
#
class SemanticLogger::Appender::Elasticsearch < SemanticLogger::Appender::Http
  attr_accessor :index, :type

  # Create Elasticsearch appender over persistent HTTP(S)
  #
  # Parameters:
  #   index: [String]
  #     Index to store the logs in Elasticsearch.
  #     Default: 'semantic_logger-YYYY.MM.DD'
  #
  #   type: [String]
  #     Document type to associate with logs when they are written.
  #     Default: 'log'
  def initialize(options, &block)
    options       = options.dup
    @index        = options.delete(:index) || "semantic_logger-#{Date.today.to_s.gsub('-', '.')}"
    @type         = options.delete(:type) || 'log'
    options[:url] ||= 'http://localhost:9200'

    super(options, &block)

    @request_uri = "#{@index}/#{@type}"
  end

  # Deletes all log data captured for this index
  def delete_all
    delete(index)
  end

end
