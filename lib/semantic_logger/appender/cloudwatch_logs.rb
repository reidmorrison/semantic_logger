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
      #
      # Formats the log message now, so that one that cannot be formatted, or that CloudWatch Logs
      # would reject, raises here for that message alone, and the buffer only holds log events
      # ready to send.
      def log(log)
        buffered_logs << log_event(log)
        put_log_events if buffered_logs.size >= max_buffered_events
        true
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

      # Returns [Hash] the PutLogEvents log event for the log message.
      def log_event(log)
        {timestamp: (log.time.to_f * 1000).floor, message: event_message(format_log(log))}
      end

      # Returns [String] the formatted log message in UTF-8, cut short to the most that a batch can
      # hold.
      #
      # Raises FormatError for a message that CloudWatch Logs would reject, together with every
      # other message in the same request: one that is not a String, or is empty.
      def event_message(message)
        unless message.is_a?(String)
          raise(FormatError, "Could not format the log message (the formatter returned a #{message.class})")
        end

        message = Utils.encode_utf8_string(message)
        raise(FormatError, "Could not format the log message (it is empty)") if message.empty?

        limit = MAX_BATCH_BYTES - EVENT_OVERHEAD_BYTES
        message.bytesize <= limit ? message : message.byteslice(0, limit).scrub("")
      end

      # Sends the buffered log events, in as many requests as the PutLogEvents limits need.
      #
      # A request that fails is reported to the internal logger rather than raised: this usually
      # runs on the timer thread, which discards errors, and the log events were already taken off
      # the buffer, so AWS rejecting a batch, for example one over the size limit, lost every
      # message in it without a trace.
      def put_log_events
        events = buffered_logs.shift(max_buffered_events)
        return if events.none?

        batches(events).each { |batch| put_batch(batch) }
      end

      # Returns [Array<Array<Hash>>] the log events in chronological order, as PutLogEvents requires,
      # split into batches that it accepts.
      def batches(events)
        batches = [[]]
        bytes   = 0
        # Keeps the order of log events with the same timestamp.
        events.each_with_index.sort_by { |event, index| [event[:timestamp], index] }.each do |event, _index|
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

      # Sends one batch, reporting any failure to the internal logger, so that the other batches are
      # still sent.
      def put_batch(events)
        response = send_batch(events)
        report_rejected_events(events, response.rejected_log_events_info)
      rescue StandardError => e
        logger.error("Could not send #{events.size} log message(s) to CloudWatch Logs", e)
      end

      # Returns the PutLogEvents response, after creating the log group or stream when it is missing
      # and this appender may create it.
      def send_batch(events)
        created = []
        begin
          client.put_log_events(log_group_name: group, log_stream_name: stream, log_events: events)
        rescue Aws::CloudWatchLogs::Errors::ResourceNotFoundException => e
          resource = missing_resource(e)
          raise if resource.nil? || created.include?(resource)

          create(resource)
          created << resource
          retry
        end
      end

      # Returns [:group | :stream | nil] the missing resource that this appender may create.
      def missing_resource(exception)
        if exception.message.include?("log group does not exist.") && create_group
          :group
        elsif exception.message.include?("log stream does not exist.") && create_stream
          :stream
        end
      end

      def create(resource)
        if resource == :group
          client.create_log_group(log_group_name: group)
        else
          client.create_log_stream(log_group_name: group, log_stream_name: stream)
        end
      rescue Aws::CloudWatchLogs::Errors::ResourceAlreadyExistsException
        # Created meanwhile, for example by another process logging to the same log group.
        nil
      end

      # PutLogEvents accepts a request in which it rejects some of the log events: those more than 2
      # hours in the future, older than 14 days, or older than the log group's retention period.
      def report_rejected_events(events, rejected)
        return unless rejected

        logger.warn(
          "CloudWatch Logs rejected some of #{events.size} log message(s) as too new, too old, or expired",
          rejected.to_h
        )
      end

      def stream
        @stream || host
      end
    end
  end
end
