# Send log entries to an OpenTelemetry collector, or any other server that receives OTLP/HTTP, as OTLP
# log records, in the binary Protobuf encoding of OTLP (http/protobuf) by default, or as OTLP/JSON
# (http/json). Needs no OpenTelemetry gems, nor the google-protobuf gem.
#
# Example:
#   SemanticLogger.add_appender(appender: :otlp)
#
#   SemanticLogger.add_appender(
#     appender: :otlp,
#     url:      "https://otlp.example.com",
#     header:   {"Authorization" => "Bearer TOKEN"}
#   )
#
# It is batched by default: each batch of log entries is posted as one ExportLogsServiceRequest to
# `<url>/v1/logs`, with the resource of the process, and one ScopeLogs for each logger name in the
# batch, its instrumentation scope named after it, such as "MyApp::Orders". Each entry is a LogRecord,
# from Formatters::Otlp.
#
# Each record is linked to the trace it was logged in, from the span that was current on the thread
# that logged it, when the opentelemetry-api gem is loaded, or else from the named tags `trace_id`
# and `span_id`, when the application sets them (see Otlp::TraceContext).
#
# Responses: as for Appender::Http, except that a 502 or 504 is sent again too, as OTLP/HTTP asks (see
# Otlp::Exporter#wrote_nothing?). A partial success, where the server stored only some of the
# records, is reported on the internal logger, and the rest are not sent again.
module SemanticLogger
  module Appender
    class Otlp < SemanticLogger::Appender::Http
      include SemanticLogger::Otlp::Exporter

      # Create an OTLP/HTTP log appender.
      #
      # Parameters:
      #   formatter: [SemanticLogger::Formatters::Otlp]
      #     Maps each log entry to a LogRecord: Formatters::Otlp, or a subclass of it. Any other
      #     formatter, or a formatter block, raises ArgumentError, since what it returns is not a
      #     LogRecord.
      #     Default: SemanticLogger::Formatters::Otlp
      #
      # The other options, and the environment variables that they take their defaults from, are those
      # of SemanticLogger::Otlp::Exporter, with LOGS for SIGNAL, such as OTEL_EXPORTER_OTLP_LOGS_ENDPOINT,
      # and of Appender::Http, such as `level:` and `filter:`. A metric-only entry, a metric without a
      # message or an exception, is left out, unless `metrics: true` is given, since it is meant for the
      # metric appenders.
      def initialize(**args, &)
        @trace_context_registered = Concurrent::AtomicBoolean.new(false)
        super
        register_trace_context
      end

      # Closes the connection, and stops capturing the trace context of each log call once no other
      # appender uses it (see Otlp::TraceContext.unregister). Closing it again, even at once on another
      # thread, unregisters nothing more. Writing again afterwards captures it again (see #batch), until it
      # is closed once more.
      def close
        super
      ensure
        SemanticLogger::Otlp::TraceContext.unregister if @trace_context_registered.make_false
      end

      # Returns [SemanticLogger::Otlp::Signal] the logs signal.
      def otlp_signal = SemanticLogger::Otlp::Signal::LOGS

      # Sets the formatter, as Subscriber#formatter= does, raising ArgumentError, and keeping the one it
      # had, for one that is not a Formatters::Otlp, since the appender sends what it returns as a
      # LogRecord.
      def formatter=(formatter)
        previous = @formatter
        super
        return if @formatter.is_a?(SemanticLogger::Formatters::Otlp)

        refused    = @formatter
        @formatter = previous
        raise(
          ArgumentError,
          "The :otlp appender needs a formatter that returns an OTLP LogRecord: " \
          "SemanticLogger::Formatters::Otlp, or a subclass of it, not: #{refused.class}"
        )
      end

      # Posts the log entry in one request.
      def log(log)
        batch([log])
      end

      # Posts the log entries in one request, with one ScopeLogs for each logger name. Returns true once
      # the server accepted it, and raises when it did not, or could not be reached.
      def batch(logs)
        register_trace_context
        scopes = Hash.new { |hash, name| hash[name] = [] }
        logs.each { |log| scopes[log.name] << format_log(log) }
        export(request(scopes))
      end

      # Batched by default, since OTLP sends log records in batches.
      def batch_by_default?
        true
      end

      # Its #batch formats each entry with #format_log, so any Formatters::Otlp can be batched.
      def batch_refusal
        nil
      end

      # Whether the exception was caused by the entries sent (see Appender::Http#message_error?),
      # including a record that the binary encoding cannot write, such as one from a subclass of
      # Formatters::Otlp with a field that a LogRecord does not have.
      def message_error?(exception)
        exception.is_a?(SemanticLogger::Otlp::Protobuf::Error) || super
      end

      private

      # Captures the trace context of each log call while the appender is open (see Otlp::TraceContext),
      # once, such as again after it was closed and is written to once more.
      def register_trace_context
        SemanticLogger::Otlp::TraceContext.register if @trace_context_registered.make_true
      end

      # Returns [Hash] the ExportLogsServiceRequest of the records, by the name of their logger.
      def request(scopes)
        {
          resourceLogs: [
            {
              resource:  {attributes: SemanticLogger::Otlp::Values.attributes(request_resource)},
              scopeLogs: scopes.map do |name, records|
                {scope: {name: SemanticLogger::Otlp::Values.text(name)}, logRecords: records}
              end
            }
          ]
        }
      end

      def default_formatter
        SemanticLogger::Formatters::Otlp.new
      end
    end
  end
end
