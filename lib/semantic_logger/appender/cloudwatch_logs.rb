begin
  require "aws-sdk-cloudwatchlogs"
rescue LoadError
  raise LoadError,
        'Gem aws-sdk-cloudwatchlogs is required for logging to CloudWatch Logs. Please add the gem "aws-sdk-cloudwatchlogs" to your Gemfile.'
end

require "concurrent"

# Forward all log messages to CloudWatch Logs.
#
# Example:
#
#   SemanticLogger.add_appender(
#     appender: :cloudwatch_logs,
#     client_kwargs: {region: "eu-west-1"},
#     group: "/my/application",
#     create_stream: true
#   )
module SemanticLogger
  module Appender
    class CloudwatchLogs < SemanticLogger::Subscriber
      attr_reader :client_kwargs, :group, :create_group, :create_stream, :force_flush_interval_seconds, :max_buffered_events,
                  :task, :client, :buffered_logs

      # Create CloudWatch Logs Appender
      #
      # Parameters:
      #   group: [String]
      #     Log group name
      #
      #   client_kwargs: [Hash]
      #     A hash to be passed to Aws::CloudWatchLogs::Client.new
      #     Default: {}
      #
      #   stream: [String]
      #     Log stream name
      #     Default: SemanticLogger.host
      #
      #   create_group: [Boolean]
      #     If the missing log group should be automatically created.
      #     Default: false
      #
      #   create_stream: [Boolean]
      #     If the missing log stream should be automatically created.
      #     Default: true
      #
      #   force_flush_interval_seconds: [Integer]
      #     Flush buffered logs every X seconds, regardless of the current buffer size.
      #     Default: 5
      #
      #   max_buffered_events: [Integer]
      #     Flush buffered logs if they are above the currently set size.
      #     Note that currently CloudWatch Logs has 10000 hard limit.
      #     Default: 4000
      def initialize(
        *args,
        group:,
        client_kwargs: {},
        stream: nil,
        create_group: false,
        create_stream: true,
        force_flush_interval_seconds: 5,
        max_buffered_events: 4_000,
        **kwargs,
        &block
      )
        @group = group
        @client_kwargs = client_kwargs
        @stream = stream
        @create_group = create_group
        @create_stream = create_stream
        @force_flush_interval_seconds = force_flush_interval_seconds
        @max_buffered_events = max_buffered_events

        super(*args, **kwargs, &block)
        reopen
      end

      # Method called to log an event
      def log(log)
        buffered_logs << log

        put_log_events if buffered_logs.size >= max_buffered_events
      end

      def flush
        task.execute while buffered_logs.size.positive?
      end

      def close
        task.shutdown
      end

      def reopen
        @buffered_logs = Concurrent::Array.new
        @client = Aws::CloudWatchLogs::Client.new(client_kwargs)

        @task = Concurrent::TimerTask.new(execution_interval: force_flush_interval_seconds,
                                          interval_type:      :fixed_rate) do
          put_log_events
        end
        @task.execute
      end

      # Use JSON Formatter by default
      def default_formatter
        SemanticLogger::Formatters::Json.new
      end

      private

      def put_log_events
        logs = buffered_logs.shift(max_buffered_events)

        return if logs.none?

        begin
          client.put_log_events({
                                  log_group_name:  group,
                                  log_stream_name: stream,
                                  log_events:      logs.map do |log|
                                                     {
                                                       timestamp: (log.time.to_f * 1000).floor,
                                                       message:   formatter.call(log, self)
                                                     }
                                                   end
                                })
        rescue Aws::CloudWatchLogs::Errors::ResourceNotFoundException => e
          if e.message.include?("log group does not exist.") && create_group
            client.create_log_group({
                                      log_group_name: group
                                    })
            retry
          elsif e.message.include?("log stream does not exist.") && create_stream
            client.create_log_stream({
                                       log_group_name:  group,
                                       log_stream_name: stream
                                     })
            retry
          end
        end
      end

      def stream
        @stream || host
      end
    end
  end
end
