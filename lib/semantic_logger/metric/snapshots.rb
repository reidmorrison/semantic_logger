module SemanticLogger
  module Metric
    # Makes an appender a metric appender: one that is given the snapshot of the metrics of each
    # interval (see Metric::Collector), and takes no log entries.
    #
    # Include it in an appender, derived from SemanticLogger::Subscriber or one of its subclasses, such
    # as SemanticLogger::Appender::Http, and implement #write_metrics(snapshot), which writes a
    # Metric::Snapshot to the destination: it returns once the destination has them, and raises when
    # it could not write them. An appender that defines its own #initialize passes the `interval:` and
    # `internal_metrics:` options on to `super`, and one that defines its own #flush, #close or #reopen
    # calls `super` from it.
    #
    #   class MyMetrics < SemanticLogger::Subscriber
    #     include SemanticLogger::Metric::Snapshots
    #
    #     def write_metrics(snapshot)
    #       snapshot.each { |point| ... }
    #     end
    #   end
    #
    #   SemanticLogger.add_appender(metric: MyMetrics.new(interval: 10))
    #
    # The snapshots that it is given have no scopes (see Snapshot::Point#scope): the series that the
    # loggers of different classes recorded with the same name and dimensions are merged into one,
    # unless the appender answers true to #metric_scopes?, since its destination keeps them apart.
    #
    # A snapshot that #write_metrics fails to write is reported and discarded, unless the appender says
    # that it is worth writing again (see #metrics_retryable?): it is then kept, and written with the
    # snapshot of its next interval, merged into one. One that the destination answered with a failure
    # is kept at most MAX_RESENDS times; one that was never sent, such as when the appender could not
    # connect (see Subscriber#not_sent?), is kept until it is written, as long as the destination is
    # down, but no larger than MAX_KEPT_POINTS points, nor longer than MAX_KEPT_SECONDS from the start
    # of its oldest interval: it is then discarded too, so that an outage neither grows the process
    # without bound nor sends a burst of stale metrics once it ends. A flush or close writes what it
    # holds, kept or not, once, and discards it when that fails.
    #
    # It knows its interval, whether it writes Semantic Logger's own metrics, the snapshot that it holds
    # until its interval has passed, the one that it keeps to write again, and in which process it holds
    # them. It takes a snapshot, and is flushed, closed and reopened, one call at a time, under a lock
    # of its own, since a snapshot handed to an appender added with async: true whose worker thread
    # had stopped is given to it on a thread of its own (see Appender::Async#log_metrics). Not in a
    # signal trap, where no lock can be taken, such as a removal that closes it there.
    module Snapshots
      # Seconds between the snapshots that a metric appender writes, by default.
      DEFAULT_INTERVAL = 60

      # Times that a snapshot the destination answered with a failure is kept to be written again,
      # with the next one, before it is discarded (see #metrics_retryable?).
      MAX_RESENDS = 3

      # Largest number of points that a snapshot kept to write again may hold: one that would hold more
      # is discarded instead (see #write_snapshots).
      MAX_KEPT_POINTS = 10_000

      # Most seconds, from the start of its oldest interval to the end of its latest, that a snapshot
      # kept to write again may span: one that would span more is discarded instead.
      MAX_KEPT_SECONDS = 3600

      # The options of a Subscriber for the log entries that it takes, which a metric appender refuses
      # (see #refused_log_entry_options), with what to do instead.
      LOG_ENTRY_OPTIONS = {
        level:     "metrics are recorded whatever the log level",
        filter:    "every metric recorded is written",
        formatter: "the appender writes them in the format of its destination"
      }.freeze

      # Parameters:
      #   interval: [Numeric]
      #     Seconds between the snapshots it writes. The snapshots of the metric appenders with a
      #     shorter interval are merged until it has passed.
      #     Default: 60
      #
      #   internal_metrics: [true|false]
      #     Whether to write Semantic Logger's own metrics too.
      #     Default: false
      #
      # The other options are those of the appender it is included in, other than the options for the
      # log entries that it would take, level:, filter:, and formatter:, and a formatter block, which
      # raise ArgumentError, since a metric appender takes none (see #refused_log_entry_options). One
      # given as nil sets nothing, so it is not refused.
      def initialize(interval: nil, internal_metrics: false, **args, &block)
        refuse_log_entry_options(args, block)
        interval ||= DEFAULT_INTERVAL
        unless interval.is_a?(Numeric) && interval.real? && interval.positive? && interval.finite?
          raise(ArgumentError, "interval: must be a positive number of seconds, not: #{interval.inspect}")
        end

        @metrics_interval = interval
        @internal_metrics = internal_metrics ? true : false
        @held_snapshot    = nil
        @kept_snapshot    = nil
        @resends          = 0
        @snapshots_pid    = ::Process.pid
        @snapshots_lock   = Mutex.new
        super(**args, &block)
      end

      # Returns [Numeric] the seconds between the snapshots it writes. Only a metric appender has one,
      # so it is given the snapshots (see Appenders#log_metrics).
      def metrics_interval = @metrics_interval

      # Returns [true|false] whether it writes Semantic Logger's own metrics too.
      def internal_metrics? = @internal_metrics

      # Returns [true|false] whether it writes the scope of each point, the name of the logger that
      # recorded it, such as OpenTelemetry's instrumentation scope, so that it is given the points of each
      # scope apart. Otherwise the series that differ only by their scope are merged before it holds them
      # (see Snapshot#without_scopes). Default: false
      def metric_scopes? = false

      # A metric appender takes no log entries.
      def should_log?(_log) = false

      # A metric appender takes no log entries, so it needs nothing captured on the thread that logs
      # them, whatever its formatter (see Subscriber#source_captures).
      def source_captures = [].freeze

      # A metric appender writes no log entry, at any level.
      def writes_level?(_log) = false

      # A metric appender takes no log entries, so it is never batched by default, even when it
      # implements #batch, or inherits one, as from Appender::Http.
      def batch_by_default? = false

      # A metric appender takes no log entries, so it cannot be batched (see Subscriber#batch_refusal).
      def batch_refusal
        "a metric appender takes no log entries, so there is nothing to batch. Add it without batch: true."
      end

      # Holds the snapshot, merged with the one it holds, without Semantic Logger's own metrics unless
      # it writes them, and without scopes unless it writes them (see #metric_scopes?), then writes
      # what it holds once its interval has passed (see #interval_ended?), with the snapshot it kept to
      # write again, if any. Returns true, or false when writing failed,
      # which it reports.
      #
      # Two snapshots may arrive out of order (see Collector#deliver), so the earlier one is merged
      # with the later one.
      def log_metrics(snapshot)
        one_at_a_time do
          forget_parent_snapshots
          snapshot       = snapshot.without_internal unless @internal_metrics
          snapshot       = snapshot.without_scopes unless metric_scopes?
          @held_snapshot = Snapshots.merged(@held_snapshot, snapshot)
          next true unless interval_ended?(snapshot)

          write_snapshots(keep: true)
        end
      end

      # Writes the snapshots it holds and keeps, once, then flushes the appender, even when writing them
      # raised.
      def flush
        flushed = nil
        one_at_a_time do
          forget_parent_snapshots
          write_snapshots(keep: false)
        ensure
          flushed = super
        end
        flushed
      end

      # Writes the snapshots it holds and keeps, once, then closes the appender, even when writing them
      # raised.
      def close
        closed = nil
        one_at_a_time do
          forget_parent_snapshots
          write_snapshots(keep: false)
        ensure
          closed = super
        end
        closed
      end

      # Discards the snapshots inherited from the parent process in a forked child, which the parent
      # writes itself, unless the child was started by Process.daemon (see CoreExt::Process.daemon?),
      # then reopens the appender, when it can. Called by SemanticLogger.reopen, through
      # Appenders#reopen.
      def reopen
        one_at_a_time do
          forget_parent_snapshots
          defined?(super) ? super : true
        end
      end

      # Writes the snapshot to the destination. Implemented by the appender: returns once written, and
      # raises when it could not write it (see #metrics_retryable?).
      def write_metrics(_snapshot)
        raise NotImplementedError, "#{self.class.name} must implement #write_metrics(snapshot)"
      end

      # Returns [true|false] whether the snapshot that #write_metrics failed to write, raising the
      # exception, is worth writing again, with the next one: a later write may succeed, such as when
      # the destination asked for it to be sent again later, or it was never sent (see
      # Subscriber#not_sent?), in which case it is kept for as long as it takes, rather than
      # MAX_RESENDS times. Otherwise it is discarded. The appender decides whether writing it again
      # can count its points twice, should the destination have stored some of it.
      #
      # False, since only the appender can tell. An appender that writes the snapshot in more than one
      # request must answer false for an error from any request after the first.
      def metrics_retryable?(_exception)
        false
      end

      # Returns [Snapshot] the two snapshots, either of which may be nil, merged in the order of their
      # start times (see Snapshot#merge).
      def self.merged(snapshot, other)
        return other if snapshot.nil?
        return snapshot if other.nil?

        other.start_time < snapshot.start_time ? other.merge(snapshot) : snapshot.merge(other)
      end

      private

      # Returns the value of the block, run holding the lock of the snapshots (see the class comment),
      # or, where it cannot be locked, in a signal trap, or on a thread that already holds it, such as
      # one writing the snapshots that flushes, without it.
      def one_at_a_time
        result = nil
        TrapSafe.try_synchronize(@snapshots_lock) { result = yield } || (result = yield)
        result
      end

      # Returns [Array<Symbol>] the options for the log entries that a Subscriber takes, which a metric
      # appender refuses, since it takes none (see #initialize): :level, :filter and :formatter, the
      # last one for a formatter block too.
      #
      # An appender that writes log entries of its own, such as the points of each snapshot as log
      # entries, overrides it to leave out :level, which then sets the level of those entries:
      #
      #   def refused_log_entry_options = super - [:level]
      def refused_log_entry_options = LOG_ENTRY_OPTIONS.keys

      # Raises ArgumentError for the options for log entries that it refuses (see
      # #refused_log_entry_options), naming each one, with what to do instead.
      def refuse_log_entry_options(args, block)
        refused = refused_log_entry_options
        given   = refused.select { |option| !args[option].nil? || (option == :formatter && block) }
        return if given.empty?

        names   = given.filter_map { |option| "#{option}:" unless args[option].nil? }
        names  << "formatter block" if block && given.include?(:formatter)
        reasons = given.map { |option| LOG_ENTRY_OPTIONS[option] }
        raise(
          ArgumentError,
          "#{self.class.name} takes no #{names.join(', ')}, since a metric appender takes no log entries: " \
          "#{reasons.join('; ')}. Remove #{names.one? ? 'it' : 'them'}."
        )
      end

      # Whether its interval has passed since the start of the snapshot that it holds, or ends nearer
      # now than when the next snapshot, assumed as long as the latest, arrives.
      def interval_ended?(latest)
        held = @held_snapshot
        (held.end_time - held.start_time) + ((latest.end_time - latest.start_time) / 2.0) >= @metrics_interval
      end

      # Writes the snapshot it kept to write again, merged with the one it holds, unless both are empty,
      # and no longer holds either one. Returns true, or false when writing it failed.
      #
      # When it fails, reports it, and, with `keep`, keeps the snapshot to write again with the next
      # one when the appender says that it is worth it (see #metrics_retryable?), counting the times it
      # does so, unless it was never sent, up to MAX_RESENDS, and when it is no larger than
      # MAX_KEPT_POINTS points, nor spans more than MAX_KEPT_SECONDS. Otherwise discards it.
      def write_snapshots(keep:)
        snapshot       = Snapshots.merged(@kept_snapshot, @held_snapshot)
        @held_snapshot = nil
        @kept_snapshot = nil
        return true if snapshot.nil? || snapshot.empty?

        begin
          write_metrics(snapshot)
          @resends = 0
          true
        rescue StandardError, ScriptError => e
          keep && keep_to_write_again?(snapshot, e) ? kept(snapshot, e) : discarded(snapshot, e)
          false
        end
      end

      # Whether the snapshot that failed with the exception is kept to write again (see
      # #write_snapshots). Counts it, unless it was never sent.
      def keep_to_write_again?(snapshot, exception)
        return false unless metrics_retryable?(exception)
        return false if too_large_to_keep?(snapshot)
        return true if not_sent?(exception)
        return false if @resends >= MAX_RESENDS

        @resends += 1
        true
      end

      # Whether the snapshot holds more than MAX_KEPT_POINTS points, or spans more than MAX_KEPT_SECONDS.
      def too_large_to_keep?(snapshot)
        snapshot.size > MAX_KEPT_POINTS || (snapshot.end_time - snapshot.start_time) > MAX_KEPT_SECONDS
      end

      def kept(snapshot, exception)
        @kept_snapshot = snapshot
        logger.warn(
          "Failed to write the metrics from #{snapshot.start_time} to #{snapshot.end_time}; " \
          "writing them again with the next ones",
          exception
        )
      end

      def discarded(snapshot, exception)
        @resends = 0
        reason   = too_large_to_keep?(snapshot) ? too_large_reason : ""
        logger.error(
          "Failed to write the metrics from #{snapshot.start_time} to #{snapshot.end_time}; discarded them#{reason}",
          exception
        )
      end

      def too_large_reason
        ", since they would have been kept with more than #{MAX_KEPT_POINTS} points, or over more than " \
          "#{MAX_KEPT_SECONDS} seconds"
      end

      # In a forked child, discards the snapshots inherited from the parent, which the parent writes
      # itself, unless the child was started by Process.daemon, whose parent exits without writing them.
      # Checked whenever it is given or writes a snapshot, too, since a child forked while
      # SemanticLogger.reopen_on_fork is false is not reopened.
      def forget_parent_snapshots
        return if @snapshots_pid == ::Process.pid

        @snapshots_pid = ::Process.pid
        return if CoreExt::Process.daemon?

        @held_snapshot = nil
        @kept_snapshot = nil
        @resends       = 0
        forget_parent_state
      end

      # In a forked child, other than one started by Process.daemon, forgets whatever else the appender
      # carries from one snapshot to the next, which the parent carries on with itself. Called by
      # #forget_parent_snapshots, holding the lock of the snapshots, before any snapshot is written in the
      # child. Does nothing, unless the appender overrides it.
      def forget_parent_state
      end
    end
  end
end
