# Loaded now rather than autoloaded, since #default_formatter builds one, such as for the internal
# logger that the processor builds on first use, which can be in a signal trap, where Ruby does not
# allow a require.
require "semantic_logger/formatters/default"
# Loaded now too, since the formatters that write the trace return its capture (see #source_captures),
# which the appenders build again once one is added, which can be in a signal trap too.
require "semantic_logger/otlp/trace_context"

# Abstract Subscriber
#
#   Abstract base class for all appenders.
module SemanticLogger
  class Subscriber < SemanticLogger::Base
    # No source capture (see #source_captures).
    NO_SOURCE_CAPTURES = [].freeze
    private_constant :NO_SOURCE_CAPTURES

    # Every appender has its own formatter
    attr_reader :formatter
    attr_writer :application, :environment, :host, :metrics

    # A subscriber should implement flush if it can.
    def flush
      # NOOP
    end

    # A subscriber should implement close if it can, and call super.
    def close
      nil
    end

    # Returns [Array<#call>] the objects to call with each log entry that this appender writes, on the
    # thread that logged it, before it is handed to the thread that writes it: to keep on the entry
    # what only that thread can read, such as the current span or a client's scope, with
    # `log.capture(key, value)`, for this appender to read with `log.captured(key)` (see
    # Log#capture), or a backtrace with `log.capture_backtrace!`. By default those of the formatter,
    # when it answers #source_captures (see Formatters::Base#source_captures), other than this
    # appender itself, when it formats its own entries with #call.
    #
    # The appenders that are added run them (see Appenders#capture): each capture once for each entry,
    # however many appenders return it, so return the same object each time, such as a constant, and
    # only for an entry that one of them writes at its level (see #writes_level?). The capture decides
    # anything more, such as to take a backtrace only for an entry without an exception. Keep them
    # fast, since they run in every log call of the application.
    #
    # An appender whose captures can change after it was added, other than by #formatter=, calls
    # SourceCaptures.changed afterwards.
    #
    # Example:
    #   CAPTURE = ->(log) { log.capture(:my_service, MyService.current_context) }
    #
    #   def source_captures = [*super, CAPTURE]
    def source_captures
      current = formatter
      return NO_SOURCE_CAPTURES if current.equal?(self) || !current.respond_to?(:source_captures)

      current.source_captures
    end

    # Returns [true|false] whether this appender's level lets it write the log entry, and, for a
    # metric-only entry, whether it writes those, as #should_log? decides, its filter aside, which
    # runs on the thread that writes it. Its source captures run for such an entry (see
    # #source_captures).
    def writes_level?(log)
      meets_log_level?(log) && (!log.metric_only? || metrics?)
    end

    # Method called to log an event
    def log(log)
      raise NotImplementedError
    end

    # Returns [SemanticLogger::Formatters::Default] default formatter for this subscriber.
    def default_formatter
      SemanticLogger::Formatters::Default.new
    end

    # Allow application name to be set globally or on a per subscriber basis.
    def application
      @application || SemanticLogger.application
    end

    # Allow environment name to be set globally or on a per subscriber basis.
    def environment
      @environment || SemanticLogger.environment
    end

    # Allow host name to be set globally or on a per subscriber basis.
    def host
      @host || SemanticLogger.host
    end

    # Give each appender its own logger for logging.
    # For example trace messages sent to services or errors when something fails.
    #
    # Unless one was set with #logger=, it is a copy of the internal logger named after the appender,
    # which follows the internal logger when it is replaced (see SemanticLogger.internal_logger=).
    def logger
      @logger || (@internal_logger_copy ||= InternalLoggerCopy.new(self.class.name, Processor)).logger
    end

    # Sets the logger of this appender, in place of the copy of the internal logger, or nil to follow
    # the internal logger again. So does the copy that #logger returns now, such as one saved to be set
    # back.
    def logger=(logger)
      @logger = @internal_logger_copy&.copy?(logger) ? nil : logger
    end

    # Set the formatter from Symbol|Hash|Block
    #
    # The appenders then build their source captures again, since this appender's are by default
    # those of its formatter (see #source_captures).
    def formatter=(formatter)
      @formatter =
        if formatter.nil?
          respond_to?(:call) ? self : default_formatter
        else
          Formatters.factory(formatter)
        end
      SourceCaptures.changed
    end

    # Whether this log entry meets the criteria to be logged by this appender.
    def should_log?(log)
      super && (log.metric_only? ? metrics? : true)
    end

    # Returns [Numeric|nil] the seconds between the snapshots of metrics that this appender writes, for
    # a metric appender (see Metric::Snapshots), which is given them (see Appenders#log_metrics).
    # Nil for any other appender, which is never given one.
    def metrics_interval
      nil
    end

    # Returns [true|false] whether this appender writes Semantic Logger's own metrics (see
    # Metric::InternalMetrics), which only a metric appender added with `internal_metrics: true` does
    # (see Metric::Snapshots).
    def internal_metrics?
      false
    end

    # Returns [Hash|nil] the cumulative counts of the log entries that this appender's own queue has
    # finished with (see Appender::Async#queue_log_counts), or nil for an appender without a queue of its own,
    # which the main queue writes to. Read for Semantic Logger's own metrics (see
    # Metric::InternalMetrics).
    def queue_log_counts
      nil
    end

    # The console stream this appender writes to, if any.
    # Returns one of :stdout, :stderr, or nil when not writing to a console stream.
    def console_stream
      nil
    end

    # Whether this appender is logging to stdout or stderr.
    def console_output?
      !console_stream.nil?
    end

    # Returns [String] the class and object address of this appender, like Kernel#inspect, followed
    # by #inspect_details, but none of its instance variables.
    #
    # Appenders hold credentials in their instance variables: passwords and urls holding them, api
    # keys and tokens, request headers, private keys, and the options passed to a client gem.
    # Printing SemanticLogger.appenders, for example in a console or an error report, must not
    # show them.
    def inspect
      address = Kernel.instance_method(:to_s).bind_call(self).delete_suffix(">")
      details = inspect_details
      details ? "#{address} #{details}>" : "#{address}>"
    end

    # Returns [String] what #inspect shows about this appender, such as its url without its
    # credentials, or nil for nothing. Only an appender knows which of its settings are safe to
    # show, so each one overrides this.
    def inspect_details
      nil
    end

    # Whether an appender that implements #batch should be wrapped in a batch
    # proxy automatically. Appenders that support batching but should only batch
    # when explicitly requested (via `batch: true`) override this to return false.
    def batch_by_default?
      true
    end

    # Returns [String] why this appender cannot be batched, and what to do instead, or nil when it
    # can. add_appender asks it before it batches the appender, with `batch: true` or by default, see
    # #batch_by_default?, and raises ArgumentError with it, after "add_appender cannot batch <class>: ",
    # rather than add an appender whose worker thread fails on every batch, and so writes nothing.
    #
    # Nil, since a #batch that writes each log message, formatted by #format_log, works with any
    # formatter. A class whose own #batch cannot write a batch, with some formatters or at all,
    # answers for that #batch, and only while it is the #batch in use (see #batch_defined_by?), so
    # that a subclass that replaces it is batched as before. Appender::Http does, since its #batch
    # formats the whole batch with #format_batch, which needs a formatter that can, see
    # #format_batch_refusal. A subclass whose #batch calls super keeps that need, so it answers too,
    # usually with #format_batch_refusal. One that inherits a #batch that its destination rejects,
    # whatever the formatter, such as Appender::ElasticsearchHttp, says why, and what to use instead.
    def batch_refusal
      nil
    end

    # Raised by #format_log and #format_batch when the formatter fails, with the formatter's
    # error as its cause. A formatter has no destination, so it can only fail because of the
    # content of the log message, whatever it raises.
    class FormatError < StandardError; end

    # Errors raised by writing a log message whose content cannot be written, such as a
    # value that cannot be serialized. Excludes JSON::ParserError, which comes from parsing a
    # response rather than from the message, except its subclass JSON::NestingError, which
    # JSON.generate raises for a value nested too deeply.
    MESSAGE_ERRORS = [FormatError, JSON::GeneratorError, JSON::NestingError, EncodingError, FloatDomainError].freeze

    # Whether the supplied exception, raised by #log or #batch, was caused by the content of a
    # log message, or is one that writing the message again cannot fix, such as a request the
    # destination refuses outright, rather than by the destination being unavailable for now.
    #
    # Waiting cannot write such a message, so an asynchronous appender discards it and carries on
    # straight away. On any other exception it backs off before carrying on, since the destination
    # may be briefly unavailable, then writes the message (or the batch) again when #wrote_nothing?
    # says that the write wrote none of it (see QueueProcessor::HeldWrite::MAX_RESENDS), or
    # otherwise carries on with the next one, having discarded it.
    #
    # Every error raised by the formatter is one (see #format_log). An appender whose client
    # raises its own errors for bad content can override this to recognize them.
    def message_error?(exception)
      MESSAGE_ERRORS.any? { |error_class| exception.is_a?(error_class) }
    end

    # Whether #batch writes none of the log messages when it raises a message error (see
    # #message_error?), for example because it formats every message before sending any.
    #
    # When true, a batch that fails with a message error is split up and each part retried,
    # so that only the offending message is discarded. When false, retrying could write some
    # messages twice, so the whole batch is discarded instead.
    def batch_all_or_nothing?
      false
    end

    # Whether the supplied exception, a message error (see #message_error?) that #batch raised,
    # would fail any batch, whatever messages it holds, such as a request the destination refuses
    # for its credentials or its url. Asked only about a message error, and only when
    # #batch_all_or_nothing? is true, or #rejected_entry names a message.
    #
    # When true, the whole batch is discarded at once, rather than split up and each part written
    # again to find the messages at fault, which would be refused in turn, about two writes for each
    # message. False, since an error caused by the content of a message is caused by some of the
    # messages in the batch.
    def fails_any_batch?(_exception)
      false
    end

    # Returns [Integer|nil] the position, counted from 0, of the log message in the batch that the
    # destination rejected, when the supplied exception, a message error (see #message_error?) that
    # #batch raised, says so, and the destination stored every message before that one. Nil when it
    # cannot tell, as by default.
    #
    # When an Integer, the messages before that one are counted as written, that one is discarded,
    # or, when the error would fail any batch (see #fails_any_batch?), it and every message after
    # it, and the messages after it are written again as a batch. So none is written twice, and
    # none that the destination did not reject is discarded, without splitting the batch to find
    # the message at fault. Appender::SplunkHttp answers it from the HTTP Event Collector's response.
    def rejected_entry(_exception)
      nil
    end

    # Whether #log or #batch, when it raised the supplied exception, wrote none of the log messages
    # it was given, so that writing them again cannot write any of them twice, and writing them
    # again later may succeed. Asked only about an exception that is not a message error (see
    # #message_error?), such as one raised because the destination is unavailable.
    #
    # When true, an asynchronous appender writes the same message, or batch, again once it has
    # backed off. Once the destination has answered it with a failure after it was written again
    # QueueProcessor::HeldWrite::MAX_RESENDS times, the appender discards it and carries on with the
    # next one, unless it gives up after async_max_retries first. A write that never reached the
    # destination (see #not_sent?) is not counted. When false, since the write may have written
    # some or all of them, such as a request whose answer timed out after the destination stored
    # it, or a batch written a message at a time, or since writing them again is bound to fail the
    # same way, they are discarded instead. A flush or close does not wait for them: while one is
    # waiting, they are discarded either way.
    #
    # A #log or #batch that writes the messages in more than one request must return false for an
    # error from any request after the first, which the destination may follow having stored the
    # messages of the earlier ones.
    #
    # False, since only the appender can tell. Appender::Http answers it from the error.
    def wrote_nothing?(_exception)
      false
    end

    # Whether #log or #batch, when it raised the supplied exception, sent nothing to the destination,
    # such as when it could not connect to it, so that the destination has not answered the write.
    # Asked only once #wrote_nothing? has returned true for the exception.
    #
    # When true, writing the message, or batch, again after such a failure does not count towards
    # QueueProcessor::HeldWrite::MAX_RESENDS: the limit is for a message the destination answers
    # with a failure every time, such as a request it answers with a 429 that never clears, while
    # one that cannot reach the destination during an outage is still written once it is back, as
    # long as the worker thread keeps trying (async_max_retries). When false, every failure counts.
    #
    # False, since only the appender can tell. Appender::Http answers it from the error.
    def not_sent?(_exception)
      false
    end

    private

    # Returns the log message formatted by this appender's formatter.
    #
    # Any StandardError the formatter raises is raised as a FormatError, with the formatter's
    # error as its cause, so that #message_error? recognizes it: an asynchronous appender then
    # discards the message instead of backing off. Appenders call this rather than formatter.call.
    # So is a ScriptError, such as the NotImplementedError of an abstract method, which would
    # otherwise stop an asynchronous appender's thread, since that rescues only a StandardError.
    #
    # A SystemStackError is raised as it is, so that rescuing StandardError does not swallow it:
    # the thread that overflowed must not keep writing (see Appenders#log).
    #
    # The block, when given, turns the formatter's output into what the appender sends, such as
    # its JSON. An error doing so is also caused by the content of the message.
    def format_log(log)
      formatted = formatter.call(log, self)
      block_given? ? yield(formatted) : formatted
    rescue StandardError, ScriptError => e
      raise FormatError, "Could not format the log message (#{Utils.exception_name(e)})"
    end

    # Returns the log messages formatted by the formatter's #batch, as for #format_log.
    #
    # A formatter that cannot format a batch, see #format_batch_refusal, is a configuration error
    # rather than bad content, so it raises ArgumentError instead, which backs off and is reported
    # like any other error from the destination. add_appender refuses such a formatter for an
    # appender whose #batch_refusal says so, such as Appender::Http, so for one of those this only
    # happens when #formatter= replaces it afterwards.
    #
    # The formatter is read once, so that one changed by #formatter= on another thread cannot be
    # swapped in between the check and the call.
    def format_batch(logs)
      batch_formatter = formatter
      refusal         = format_batch_refusal(batch_formatter)
      raise(ArgumentError, "Cannot batch #{self.class}: #{refusal}") if refusal

      begin
        batch_formatter.batch(logs, self)
      rescue StandardError, ScriptError => e
        raise FormatError, "Could not format the batch of log messages (#{Utils.exception_name(e)})"
      end
    end

    # Returns [String] why #format_batch cannot format a batch with the formatter, and what to do
    # instead, or nil when it can. It needs a formatter that implements #batch(logs, logger), which a
    # formatter block or Proc does not, other than this appender itself, which is its own formatter
    # when it implements #call, and whose #batch is the appender's own. Such an appender sets the
    # format of each entry that its destination takes, so the only advice for it is `batch: false`.
    #
    # #format_batch raises with it, and a #batch_refusal that answers for a #batch that calls
    # #format_batch, such as that of Appender::Http, returns it, so that both give the same answer.
    def format_batch_refusal(batch_formatter = formatter)
      if batch_formatter.equal?(self)
        "it is its own formatter, which cannot format a batch. Add it with batch: false."
      elsif !batch_formatter.respond_to?(:batch)
        "its formatter, #{batch_formatter.class}, cannot format a batch. Give it a formatter that " \
          "implements #batch(logs, logger), or add it with batch: false."
      end
    end

    # Returns [true|false] whether the #batch in use is the one that `owner` defines, for a
    # #batch_refusal that answers only for its own #batch, such as that of Appender::Http. False for
    # any other, even one that calls super, such as one that a subclass, a prepended module, or the
    # appender itself defines, and when it has none. Kernel#method finds it, since an appender may
    # define a #method of its own, such as for the HTTP method of its requests.
    def batch_defined_by?(owner)
      respond_to?(:batch) && Kernel.instance_method(:method).bind_call(self, :batch).owner.equal?(owner)
    end

    # Returns [Hash] a copy of the supplied options, with a copy of each Hash among them, such as ssl:, for an
    # appender to add its own settings to, or to give to a client it builds, which may change them. An
    # appender never changes the Hashes it is given, which belong to the application: they can be frozen, or
    # shared with another appender, and the next client the appender builds, such as after a reopen, needs
    # them as they were.
    def copy_options(options)
      options.transform_values { |value| value.is_a?(Hash) ? value.dup : value }
    end

    # Initializer for Abstract Class SemanticLogger::Subscriber
    #
    # Parameters
    #   level: [:trace | :debug | :info | :warn | :error | :fatal]
    #     Override the log level for this subscriber.
    #     Default: none (:trace), so it writes every entry that a logger emits; each logger filters by
    #     its own level (see #fallback_level).
    #
    #   formatter: [Object|Proc]
    #     An instance of a class that implements #call, or a Proc to be used to format
    #     the output from this subscriber
    #     Default: Use the built-in formatter (See: #call)
    #
    #   filter: [Regexp|Proc]
    #     RegExp: Only include log messages where the class name matches the supplied.
    #     regular expression. All other messages will be ignored.
    #     Proc: Only include log messages where the supplied Proc returns true
    #           The Proc must return true or false.
    #
    #   application: [String]
    #     Name of this application to appear in log messages.
    #     Default: SemanticLogger.application
    #
    #   host: [String]
    #     Name of this host to appear in log messages.
    #     Default: SemanticLogger.host
    #
    #   metrics: [Boolean]
    #     Whether to log metric only entries with this subscriber.
    #     Default: false
    def initialize(level: nil, formatter: nil, filter: nil, application: nil, environment: nil, host: nil,
                   metrics: false, &block)
      self.formatter = block || formatter
      @application   = application
      @environment   = environment
      @host          = host
      @metrics       = metrics

      # Subscribers don't take a class name, so use this class name if a subscriber
      # is logged to directly.
      super(self.class, level, filter)
    end

    # Without a level of its own, a subscriber logs everything it receives.
    def fallback_level
      :trace
    end

    def fallback_level_index
      0
    end

    # Whether to log metric only entries with this subscriber
    def metrics?
      @metrics
    end
  end
end
