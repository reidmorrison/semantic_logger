# Splunk log appender.
#
# Use the newer, faster and more complete JSON over HTTP interface for Splunk.
#
# To configure Splunk to receive log messages via this appender:
#   http://dev.splunk.com/view/event-collector/SP-CAAAE7F
#
# Example
#   appender = SemanticLogger::Appender::SplunkHttp(
#     url: 'http://cltlog1:8088'
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
  def initialize(options, &block)
    options      = options.dup
    @source_type = options.delete(:source_type)
    @index       = options.delete(:index)
    token        = options.delete(:token)
    raise(ArgumentError, 'Missing mandatory parameter :url') unless token

    super(options, &block)

    @header['Authorization'] = "Splunk #{token}"
  end

  # Returns [String] JSON to send to Splunk
  # For splunk format requirements see:
  #   http://dev.splunk.com/view/event-collector/SP-CAAAE6P
  def default_formatter
    proc do |log|
      h                     = {}
      message               = {
        source: @application_name,
        host:   @hostname,
        time:   log.time.utc.to_f,
        event:  h
      }
      message[:source_type] = @source_type if @source_type
      message[:index]       = @index if @index

      # Header
      h[:pid]               = $$
      h[:thread]            = log.thread_name
      file, line            = log.file_name_and_line
      if file
        h[:file] = file
        h[:line] = line
      end
      h[:level]    = log.level.to_s

      # Tags
      h[:tags]     = log.tags if log.tags && (log.tags.size > 0)

      # Duration
      h[:duration] = log.duration_human if log.duration

      # Class / app name
      h[:name]     = log.name

      # Log message
      h[:message]  = log.cleansed_message if log.message

      # Payload
      if log.payload
        if log.payload.is_a?(Hash)
          h.merge!(log.payload)
        else
          h[:payload] = log.payload
        end
      end

      # Exceptions
      if log.exception
        if log.message
          h[:message] << ' -- '
        else
          h[:message] = ''
        end
        h[:message] << "#{log.exception.class.name}: #{log.exception.message}"
        h[:backtrace] = log.backtrace_to_s
      end

      # Metric
      h[:metric] = log.metric if log.metric

      # Render to JSON
      message.to_json
    end
  end

end
