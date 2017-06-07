# Forward application metrics to SignalFx.
#
# Example:
#   SemanticLogger.add_appender(
#     appender: :signalfx,
#     token:    'YOUR_ORG_ACCESS_TOKEN'
#   )
class SemanticLogger::Appender::Signalfx < SemanticLogger::Appender::Http
  attr_reader :full_url

  END_POINT = 'v2/datapoint'

  # Create SignalFx metrics appender.
  #
  # Parameters:
  #   token: [String]
  #     Access Token to use for sending metrics.
  #     Obtain the Signalfx token via the Signalfx Web UI under `Organization` -> `Access Tokens`.
  #
  #   dimensions: [Array<String>]
  #     Dimensions to forward to signalfx when they are present in the named tags of any log message.
  #     By default `application` and `host` are always included as dimensions in all forwarded metrics.
  #     Example: [:user_id, :state]
  #
  #   filter: [Regexp|Proc]
  #     RegExp: Only include log messages where the class n, read_timeout: read_timeout, open_timeout: open_timeoutame matches the supplied.
  #     regular expression. All other messages will be ignored.
  #     Proc: Only include log messages where the supplied Proc returns true.
  #           The Proc must return true or false.
  #
  #   host: [String]
  #     Name of this host to send as a dimension.
  #     Default: SemanticLogger.host
  #
  #   application: [String]
  #     Name of this application to send as a dimension.
  #     Default: SemanticLogger.application
  #
  #   url: [String]
  #     Override the SignalFx service url.
  #     For historical data use: https://backfill.signalfx.com/v1/backfill
  #     Default: https://ingest.signalfx.com
  def initialize(token:,
                 dimensions: nil,
                 url: 'https://ingest.signalfx.com',
                 open_timeout: 2.0,
                 read_timeout: 1.0,
                 continue_timeout: 1.0,
                 filter: nil,
                 application: nil,
                 host: nil,
                 formatter: nil,
                 &block)

    formatter ||= SemanticLogger::Formatters::Signalfx.new(token: token, dimensions: dimensions)

    super(
      url:              url,
      read_timeout:     read_timeout,
      open_timeout:     open_timeout,
      continue_timeout: continue_timeout,
      filter:           filter,
      application:      application,
      host:             host,
      formatter:        formatter,
      &block
    )

    @header['X-SF-TOKEN'] = token
    @full_url             = "#{url}/#{END_POINT}"
  end

  def log(log)
    message = formatter.call(log, self)
    logger.trace(message)
    post(message, full_url)
  end

  # Logs in batches
  def batch(logs)
    message = formatter.batch(logs, self)
    logger.trace(message)
    post(message, full_url)
  end

  # Only forward log entries that contain metrics.
  def should_log?(log)
    log.metric && super
  end

end

