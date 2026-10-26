begin
  require "aws-sdk-cloudwatchlogs"
rescue LoadError
  raise LoadError,
        "Gem aws-sdk-cloudwatchlogs is required for logging to CloudWatch Logs. " \
        'Please add the gem "aws-sdk-cloudwatchlogs" to your Gemfile.'
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
      # PutLogEvents limits, from the AWS documentation: a batch holds at most MAX_BATCH_EVENTS
      # events, and at most MAX_BATCH_BYTES counting each event's message in UTF-8 plus
      # EVENT_OVERHEAD_BYTES, in chronological order.
      MAX_BATCH_BYTES      = 1_048_576
      MAX_BATCH_EVENTS     = 10_000
      EVENT_OVERHEAD_BYTES = 26

      attr_reader :client_kwargs, :group, :create_group, :create_stream,
                  :force_flush_interval_seconds, :max_buffered_events,
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
        *,
        group:,
        client_kwargs: {},
        stream: nil,
        create_group: false,
        create_stream: true,
        force_flush_interval_seconds: 5,
        max_buffered_events: 4_000,
        **,
        &
      )
        @group = group
        @client_kwargs = client_kwargs
        @stream = stream
        @create_group = create_group
        @create_stream = create_stream
        @force_flush_interval_seconds = force_flush_interval_seconds
        @max_buffered_events = max_buffered_events

        super(*, **, &)
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

      # Only the log group and stream: the client options can hold AWS credentials. See
      # Subscriber#inspect.
      def inspect_details
        "group=#{group.inspect} stream=#{stream.inspect}"
      end

      private

      # Sends the buffered log messages, in as many requests as the PutLogEvents limits need.
      #
      # A request that fails is reported to the internal logger rather than raised: this usually
      # runs on the timer thread, which discards errors, and the log messages were already taken off
      # the buffer, so AWS rejecting a batch, for example one over the size limit, lost every
      # message in it without a trace.
      def put_log_events
        logs = buffered_logs.shift(max_buffered_events)
        return if logs.none?

        log_event_batches(logs).each { |events| put_batch(events) }
      end

      # Returns [Array<Array<Hash>>] the log events for the log messages, oldest first, split into
      # batches that PutLogEvents accepts.
      def log_event_batches(logs)
        batches = [[]]
        bytes   = 0
        log_events(logs).each do |event|
          size = event[:message].bytesize + EVENT_OVERHEAD_BYTES
          if batches.last.size >= MAX_BATCH_EVENTS || bytes + size > MAX_BATCH_BYTES
            batches << []
            bytes = 0
          end
          batches.last << event
          bytes += size
        end
        batches.reject(&:empty?)
      end

      # Returns [Array<Hash>] the log events for the log messages, in chronological order, as
      # PutLogEvents requires. A message too large for a batch on its own is cut short, and one that
      # cannot be formatted is reported and left out, rather than losing the others with it.
      def log_events(logs)
        events = logs.filter_map do |log|
          {timestamp: (log.time.to_f * 1000).floor, message: event_message(format_log(log))}
        rescue FormatError => e
          logger.error("Discarded a log message from #{log.name} that could not be formatted", e)
          nil
        end
        # Keeps the order of log messages with the same timestamp.
        events.each_with_index.sort_by { |event, index| [event[:timestamp], index] }.map(&:first)
      end

      # Returns [String] the message, cut short to the most that a batch can hold.
      def event_message(message)
        limit = MAX_BATCH_BYTES - EVENT_OVERHEAD_BYTES
        message.bytesize <= limit ? message : message.byteslice(0, limit).scrub("")
      end

      def put_batch(events)
        client.put_log_events(log_group_name: group, log_stream_name: stream, log_events: events)
      rescue Aws::CloudWatchLogs::Errors::ResourceNotFoundException => e
        if e.message.include?("log group does not exist.") && create_group
          client.create_log_group(log_group_name: group)
          retry
        elsif e.message.include?("log stream does not exist.") && create_stream
          client.create_log_stream(log_group_name: group, log_stream_name: stream)
          retry
        else
          report_failed_batch(events, e)
        end
      rescue StandardError => e
        report_failed_batch(events, e)
      end

      def report_failed_batch(events, exception)
        logger.error("Could not send #{events.size} log message(s) to CloudWatch Logs", exception)
      end

      def stream
        @stream || host
      end
    end
  end
end
