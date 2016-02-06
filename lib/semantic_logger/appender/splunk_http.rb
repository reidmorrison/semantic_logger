# Splunk log appender.
#
# Use the newer, faster and more complete JSON over HTTP interface for Splunk.
#
# To configure Splunk to receive log messages via this appender:
#   http://dev.splunk.com/view/event-collector/SP-CAAAE7F
#
# Example
#   appender = SemanticLogger::Appender::SplunkHttp.new(
#     url:   'http://localhost:8080',
#     token: '70CA900C-3D7E-42A4-9C79-7975D1C422A8'
#   )
#   SemanticLogger.add_appender(appender)
class SemanticLogger::Appender::SplunkHttp < SemanticLogger::Appender::Http
  # Create Splunk appender over persistent HTTP(S)
  #
  # Parameters:
  #   token: [String]
  #     Token created in Splunk for this HTTP Appender
  #     Mandatory.
  #
  #   source_type: [String]
  #     Optional: Source type to display in Splunk
  #
  #   index: [String]
  #     Optional: Name of a valid index for this message in Splunk.
  #
  #   compress: [true|false]
  #     Whether to compress the JSON string with GZip
  #     Default: true
  def initialize(options, &block)
    options      = options.dup
    @source_type = options.delete(:source_type)
    @index       = options.delete(:index)
    token        = options.delete(:token)
    raise(ArgumentError, 'Missing mandatory parameter :token') unless token

    # Splunk supports HTTP Compression, enable by default
    options[:compress] ||= true
    super(options, &block)

    @header['Authorization'] = "Splunk #{token}"
  end

  # Returns [String] JSON to send to Splunk
  # For splunk format requirements see:
  #   http://dev.splunk.com/view/event-collector/SP-CAAAE6P
  def default_formatter
    Proc.new do |log|
      h = log.to_h
      h.delete(:time)
      message               = {
        source: @application_name,
        host:   @hostname,
        time:   log.time.utc.to_f,
        event:  h
      }
      message[:source_type] = @source_type if @source_type
      message[:index]       = @index if @index

      # Render to JSON
      message.to_json
    end
  end

end
