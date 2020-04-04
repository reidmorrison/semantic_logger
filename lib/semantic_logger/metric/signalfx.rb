# Forward application metrics to SignalFx.
#
# Example:
#   SemanticLogger.add_appender(
#     metric: :signalfx,
#     token:  'SIGNALFX_ORG_ACCESS_TOKEN'
#   )
module SemanticLogger
  module Metric
    class Signalfx < SemanticLogger::Appender::Http
      attr_reader :full_url

      END_POINT = "v2/datapoint".freeze

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
      #     RegExp: Only include log messages where the class name matches the supplied
      #             regular expression. All other messages will be ignored.
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
      #
      # Notes:
      #
      # When sending a metric to Signalfx, it is necessary to send both a `gauge` and a `counter` when a
      # duration is included in the metric, otherwise it is not possible to chart counts of the metric.
      # Unfortunately this doubles the number of metrics, but it is the way Signalfx works.
      # Using a `count` of a `gauge` in a chart will significantly under-count the number of occurrences.
      #
      # If dimensions are added to the metric, then the metric will be sent as-is and
      # the above logic will _not_ be applied.
      #
      # Example, Gauge metric, supplying the duration in `metric_amount`:
      #   logger.info(metric: 'Filters.average', metric_amount: 1.2, dimensions: {user: 'jbloggs'})
      #
      # Example, Counter metric:
      #   logger.info(metric: 'Filters.count', dimensions: {user: 'jbloggs'})
      #
      # Example, Counter metric with a count other than 1:
      #   logger.info(metric: 'Filters.count', metric_amount: 23, dimensions: {user: 'jbloggs'})
      #
      # When a duration is supplied and no dimensions are supplied:
      #   logger.info(metric: 'Common/User/authorize', duration: 1.4)
      #
      # Then it is translated into the following 2 log entries under the covers:
      #   logger.info(metric: 'Application.average', metric_amount: 1.4, dimensions: {class: 'Common::User', action: 'authorize'})
      #   logger.info(metric: 'Application.counter', metric_amount: 1, dimensions: {class: 'Common::User', action: 'authorize'})
      #
      # Similarly with a measure block which automatically supplies the duration:
      #   logger.measure_info(metric: 'Common/User/authorize') do
      #     sleep 1
      #   end
      def initialize(token:,
                     dimensions: nil,
                     url: "https://ingest.signalfx.com",
                     formatter: nil,
                     **args,
                     &block)

        formatter ||= SemanticLogger::Formatters::Signalfx.new(token: token, dimensions: dimensions)

        super(url: url, formatter: formatter, **args, &block)

        @header["X-SF-TOKEN"] = token
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
        log.metric && meets_log_level?(log) && !filtered?(log)
      end
    end
  end
end
