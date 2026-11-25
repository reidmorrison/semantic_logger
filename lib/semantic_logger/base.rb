# Base logger
#
#   Abstract base class for loggers
#
#   Implements common behavior such as log level, default text formatter etc
#
module SemanticLogger
  class Base
    # Class name to be logged
    attr_accessor :name, :filter

    # Set the logging level for this logger
    #
    # Note: This level is only for this particular instance. It does not override
    #   the log level in any logging instance or the default log level
    #   SemanticLogger.default_level
    #
    # Must be one of the values in SemanticLogger::LEVELS, or nil to use this instance's fallback
    # level (see #fallback_level).
    def level=(level)
      if level.nil?
        # Use the fallback level for this instance (see #fallback_level)
        @level_index = nil
        @level       = nil
      else
        @level_index = Levels.index(level)
        @level       = Levels.level(@level_index)
      end
    end

    # Returns the level set by an enclosing `#with_level` block on the current fiber,
    # otherwise the level set for this instance, otherwise its fallback level (see #fallback_level).
    def level
      index = @with_level_used && with_level_index
      return Levels.level(index) if index

      @level || fallback_level
    end

    # Change the log level of this instance while the block runs, on the current fiber only.
    #
    # Other threads and fibers that share this instance keep logging at its own level.
    # The level set with `#level=` is left untouched, so an instance that follows the
    # global default level keeps following it after the block. Blocks can be nested.
    #
    # Matches Ruby's `Logger#with_level`, which Sidekiq calls to apply a job's `log_level`.
    # Accepts the same levels as `#level=`. Returns the result of the block.
    def with_level(level, &)
      index            = Levels.index(level)
      @with_level_used = true
      Context.with_level(self, index, &)
    end

    # Implement the log level calls
    #   logger.debug(message, hash|exception=nil, &block)
    #
    # Implement the log level query
    #   logger.debug?
    #
    # Parameters:
    #   message
    #     [String] text message to be logged
    #     Should always be supplied unless the result of the supplied block returns
    #     a string in which case it will become the logged message
    #     Default: nil
    #
    #   payload
    #     [Hash|Exception] Optional hash payload or an exception to be logged
    #     Default: nil
    #
    #   exception
    #     [Exception] Optional exception to be logged
    #     Allows both an exception and a payload to be logged
    #     Default: nil
    #
    # Examples:
    #    require 'semantic_logger'
    #
    #    # Log :info and above
    #    SemanticLogger.default_level = :info
    #
    #    # Log to screen
    #    SemanticLogger.add_appender(io: $stdout, formatter: :color)
    #
    #    # And log to a file at the same time
    #    SemanticLogger.add_appender(file_name: 'application.log', formatter: :color)
    #
    #    logger = SemanticLogger['MyApplication']
    #    logger.debug("Only display this if log level is set to Debug or lower")
    #
    #    # Log semantic information along with a text message
    #    logger.info("Request received", user: "joe", duration: 100)
    #
    #    # Log an exception in a semantic way
    #    logger.info("Parsing received XML", exc)
    #
    SemanticLogger::Levels::LEVELS.each_with_index do |level, index|
      class_eval <<~METHODS, __FILE__, __LINE__ + 1
        def #{level}(message=nil, payload=nil, exception=nil, &block)
          if level_index <= #{index}
            log_internal(:#{level}, #{index}, message, payload, exception, &block)
            true
          else
            # Records its metric, when it has one (see #record_metric_below_level).
            record_metric_below_level(message, payload, exception)
            false
          end
        end

        def #{level}?
          level_index <= #{index}
        end

        # no_params: whether params was left out, so that below the level, a call without params
        # checks only whether its message is a Hash of options that could carry a metric.
        #
        # Below the level, the metric is recorded only when the options have a metric: value before
        # the call; one that the block adds to them is not, so that a call without one never times
        # its block.
        def measure_#{level}(message, params = (no_params = true; {}), &block)
          if level_index <= #{index}
            measure_internal(:#{level}, #{index}, message, params, &block)
          elsif no_params ? message.is_a?(Hash) : params.is_a?(Hash) && (params.key?(:metric) || message.is_a?(Hash))
            measure_below_level(message, params, &block)
          elsif block
            block.call(params)
          end
        end
      METHODS
    end

    # Dynamically supply the log level with every measurement call
    def measure(level, message, params = {}, &block)
      index = Levels.index(level)
      if level_index <= index
        measure_internal(level, index, message, params, &block)
      elsif message.is_a?(Hash) || (params.is_a?(Hash) && params.key?(:metric))
        measure_below_level(message, params, &block)
      elsif block
        yield(params)
      end
    end

    # Metrics: increment, time, and record.
    #
    # They do not depend on the log level, and log nothing. Once a metric appender is present, such as
    # `SemanticLogger.add_appender(metric: :statsd)`, each call is aggregated on the calling thread, and
    # the metric appenders are given what was recorded in each interval. Without one, they return at
    # once.
    #
    # Their dimensions are only the ones given: the tags and named tags, those of a child logger
    # returned by `#tagged` included, are never added to them, since each new value of a dimension
    # starts another series.
    #
    # Like log calls, they never raise. A metric with a name that is not a non-empty String or Symbol,
    # a value that is not a real Numeric finite as a Float, a negative counter amount, or dimensions
    # that are not a Hash, is dropped, with a warning on the internal logger once per metric name and
    # problem, as is one that fails as it is recorded. A Symbol name is recorded as a String.
    #
    # The `metric:` of a log call, a `measure_*` call, or `#backtrace` is recorded the same way, once a
    # metric appender is present, at every level and whether or not its `min_duration:` is met: as a
    # histogram of its `duration:` in seconds when it has one, as a measure call does, otherwise as a
    # counter of its `metric_amount:`, 1 by default, with its `dimensions:`. Its log entry still follows
    # the log level. Below the level, a measure call times its block only when its options have a
    # `metric:` before the call, so a metric that the block adds to them is recorded only when the level
    # passes; likewise a logging block is not called, so the metric of a Hash it returns is recorded
    # only when the level passes.

    # Adds `amount` to the counter `name`.
    #
    #   logger.increment("users.signup")
    #   logger.increment("cart.items_added", 3, dimensions: {department: "clothing"})
    #   logger.increment("messaging.client.sent.messages", unit: "{message}")
    #
    # Parameters:
    #   name [String|Symbol]
    #     Name of the counter.
    #   amount [Integer|Float]
    #     Amount to add, zero or more. A negative amount is dropped.
    #     Default: 1
    #   unit [String]
    #     Unit of what it counts, in the notation of OpenTelemetry (UCUM), such as "{message}", or "By"
    #     for bytes. Part of the identity of the series, as for #record.
    #   dimensions [Hash]
    #     Dimensions of the series to add it to.
    #
    # Returns [true|false] whether it was recorded: false without a metric appender, or when dropped.
    def increment(name, amount = 1, unit: nil, dimensions: nil)
      record_metric(:counter, name, amount, unit: unit, dimensions: dimensions)
    end

    # Records how long the block takes, in seconds, in the histogram `name`, with the unit "s", and
    # returns the block's result. The time is recorded however the block ends: when it raises, which
    # is then raised again, and when it returns or breaks out early.
    #
    #   logger.time("supplier.add_user") { supplier.add_user(user) }
    #
    # Or, without a block, records a duration measured elsewhere, given in milliseconds like the
    # `duration:` of a log call:
    #
    #   logger.time("sidekiq.queue.latency", duration: latency_ms)
    #
    # With a block, `duration:` is ignored. Without either, nothing is recorded, as for any duration
    # that is not a Numeric.
    #
    # Parameters:
    #   name [String|Symbol]
    #     Name of the histogram.
    #   duration [Numeric]
    #     Milliseconds to record, without a block.
    #   dimensions [Hash]
    #     Dimensions of the series to record it in.
    #
    # Returns the block's result. Without a block, [true|false] whether it was recorded.
    def time(name, duration: nil, dimensions: nil)
      unless block_given?
        begin
          seconds = Log.duration_seconds(duration)
        rescue StandardError => e
          return report_metric_failure(:histogram, name, e)
        end
        return record_metric(:histogram, name, seconds, unit: "s", dimensions: dimensions)
      end

      start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      begin
        yield
      ensure
        seconds = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - start
        record_metric(:histogram, name, seconds, unit: "s", dimensions: dimensions)
      end
    end

    # Records `value` in the histogram `name`, such as a size or a count of items, whose distribution
    # (count, sum, minimum, maximum, and percentiles) the metric appenders write.
    #
    #   logger.record("order.items", order.items.size)
    #   logger.record("upload.size", file.size, unit: "By")
    #
    # Parameters:
    #   name [String|Symbol]
    #     Name of the histogram.
    #   value [Numeric]
    #     Value to record. May be negative.
    #   unit [String]
    #     Unit of the values, in the notation of OpenTelemetry (UCUM), such as "By" for bytes or "s" for
    #     seconds. Part of the identity of the series, so that values in two units are never combined.
    #   dimensions [Hash]
    #     Dimensions of the series to record it in.
    #
    # Returns [true|false] whether it was recorded: false without a metric appender, or when dropped.
    def record(name, value, unit: nil, dimensions: nil)
      record_metric(:histogram, name, value, unit: unit, dimensions: dimensions)
    end

    # Log a thread backtrace
    def backtrace(thread: Thread.current,
                  level: :warn,
                  message: "Backtrace:",
                  payload: nil,
                  metric: nil,
                  metric_amount: nil)
      # The entry has the name, tags, and named tags of the thread whose backtrace it logs.
      log = new_log(level, nil, thread)
      unless meets_log_level?(log)
        record_log_metric(metric, metric_amount, nil, nil) if metric && collecting_metrics?
        return false
      end

      backtrace = thread == Thread.current ? Utils.extract_backtrace(caller) : thread.backtrace
      if backtrace
        message += "\n"
        message << backtrace.join("\n")
      end

      should_log = log.assign(message:       message,
                              backtrace:     backtrace,
                              payload:       payload,
                              metric:        metric,
                              metric_amount: metric_amount)
      record_metric_of(log)
      should_log && !filtered?(log) ? self.log(log) : false
    end

    # Add the tags or named tags to the list of tags to log for this thread whilst the supplied block is active.
    #
    # Returns result of block.
    #
    # Tagged example:
    #   SemanticLogger.tagged(12345, 'jack') do
    #     logger.debug('Hello World')
    #   end
    #
    # Named Tags (Hash) example:
    #   SemanticLogger.tagged(tracking_number: 12345) do
    #     logger.debug('Hello World')
    #   end
    #
    # Notes:
    # - Named tags are the recommended approach since the tag consists of a name value pair this is more useful
    #   than just a string value in the logs, or centralized logging system.
    # - This method is slow when using multiple text tags since it needs to flatten the tags and
    #   remove empty elements to support Rails 4.
    # - It is recommended to keep tags as a list without any empty values, or contain any child arrays.
    #   However, this api will convert:
    #     `logger.tagged([['first', nil], nil, ['more'], 'other'])`
    #   to:
    #     `logger.tagged('first', 'more', 'other')`
    # - For better performance with clean tags, see `SemanticLogger.tagged`.
    #
    # Child logger:
    # - When called *without* a block, returns a new logger instance that permanently
    #   carries the supplied tags ("instance tags"). Those tags are added to every log
    #   entry emitted by the returned logger, and _only_ that logger, even across threads.
    #   Unlike the block form they are not pushed onto the thread, so other loggers are
    #   unaffected. This is the recommended way to bind a logger to an object's identity:
    #     logger = SemanticLogger['Cart'].tagged(cart_id: cart.id)
    def tagged(*tags)
      # No block: build a child logger that carries these tags on every entry.
      return tagged_child(tags) unless block_given?

      block = -> { yield(self) }
      # Allow named tags to be passed into the logger
      # Rails::Rack::Logger passes logs as an array with a single argument
      if tags.size == 1 && !tags.first.is_a?(Array)
        tag = tags[0]
        return yield if tag.nil? || tag == ""

        return tag.is_a?(Hash) ? SemanticLogger.named_tagged(tag, &block) : SemanticLogger.fast_tag(tag.to_s, &block)
      end

      # Need to flatten and reject empties to support calls from Rails 4
      new_tags = tags.flatten.collect(&:to_s).reject(&:empty?)
      SemanticLogger.tagged(*new_tags, &block)
    end

    # :nodoc:
    alias with_tags tagged

    # :nodoc:
    def tags
      SemanticLogger.tags
    end

    def named_tags
      SemanticLogger.named_tags
    end

    # Tags permanently bound to this logger instance via `#tagged` (without a block).
    # Empty for a regular (non-child) logger.
    attr_reader :instance_tags, :instance_named_tags

    # Returns the list of tags pushed after flattening them out and removing blanks
    #
    # Note:
    # - This method is slow since it needs to flatten the tags and remove empty elements
    #   to support Rails 4.
    # - For better performance with clean tags, use `SemanticLogger.push_tags`
    def push_tags(*tags)
      # Need to flatten and reject empties to support calls from Rails 4
      new_tags = tags.flatten.collect(&:to_s).reject(&:empty?)
      SemanticLogger.push_tags(*new_tags)
    end

    # :nodoc:
    def pop_tags(quantity = 1)
      SemanticLogger.pop_tags(quantity)
    end

    # :nodoc:
    def silence(new_level = :error, &)
      SemanticLogger.silence(new_level, &)
    end

    # :nodoc:
    def fast_tag(tag, &)
      SemanticLogger.fast_tag(tag, &)
    end

    # Write log data to underlying data storage
    def log(_log_)
      raise NotImplementedError, "Logging Appender must implement #log(log)"
    end

    # Whether this log entry meets the criteria to be logged by this appender.
    def should_log?(log)
      meets_log_level?(log) && !filtered?(log)
    end

    protected

    # Only assigned to when building a child logger via `#tagged` (see #tagged_child).
    attr_writer :instance_tags, :instance_named_tags

    private

    # Initializer for Abstract Class SemanticLogger::Base
    #
    # Parameters
    #  klass [String]
    #   Name of the class, module, or other identifier for which the log messages
    #   are being logged
    #
    #  level [Symbol]
    #    Only allow log entries of this level or higher to be written to this appender
    #    For example if set to :warn, this appender would only log :warn and :fatal
    #    log messages when other appenders could be logging :info and lower
    #
    #  filter [Regexp|Proc|Module]
    #    RegExp: Only include log messages where the class name matches the supplied
    #    regular expression. All other messages will be ignored
    #    Proc: Only include log messages where the supplied Proc returns true
    #          The Proc must return true or false
    #    Module: A module that implements `.call`. For example:
    #      module ComplexFilter
    #        def self.call(log)
    #          (/\AExclude/ =~ log.message).nil?
    #        end
    #      end
    def initialize(klass, level = nil, filter = nil)
      # Support filtering all messages to this logger instance.
      unless filter.nil? || filter.is_a?(Regexp) || filter.is_a?(Proc) || filter.respond_to?(:call)
        raise ":filter must be a Regexp, Proc, or implement :call"
      end

      @filter              = filter.is_a?(Regexp) ? filter.freeze : filter
      @name                = klass.is_a?(String) ? klass : klass.name
      # `[].freeze` / `{}.freeze` compile to `opt_ary_freeze` / `opt_hash_freeze`, which return
      # a shared frozen singleton. Every logger points at the same two objects, so these default
      # (empty) instance tags allocate no garbage. Child loggers replace them via #tagged_child.
      @instance_tags       = [].freeze
      @instance_named_tags = {}.freeze
      # Set the first time `#with_level` is called on this instance, so that instances that
      # never use it skip the fiber-local lookup when checking their level. Only the fiber
      # that sets an override needs to see the flag, and that fiber set it itself.
      @with_level_used     = false
      if level.nil?
        # Use the fallback level for this instance (see #fallback_level)
        @level_index = nil
        @level       = nil
      else
        self.level = level
      end
    end

    # Every metric call (see #increment) ends here: asks the processor to record it, which drops it at
    # once without a metric appender (see Metric::Collector#record).
    #
    # Never raises, so that a metric call, like a log call, never fails the application, and #time never
    # replaces the exception of its block: when the processor raises, such as a stand-in for it in a
    # test, the failure is reported once for the metric name (see Metric::Collector#report_failure).
    #
    # kind: :counter or :histogram.
    #
    # Returns [true|false] whether it was recorded.
    def record_metric(kind, name, value, unit:, dimensions:)
      Logger.processor.record_metric(kind, name, value, unit: unit, dimensions: dimensions, scope: self.name)
    rescue StandardError => e
      report_metric_failure(kind, name, e)
    end

    # Reports, once for the metric name, that the metric call failed with `exception` (see
    # Metric::Collector#report_failure), and returns false, the result of the metric call. Never raises.
    def report_metric_failure(kind, name, exception)
      Metric.collector.report_failure(kind, name, exception)
    rescue StandardError
      # Such as outside the main Ractor, which has no collector: reporting it is best effort.
      false
    end

    # Returns [true|false] whether the metric calls are collected: true once a metric appender is present
    # (see Processor#collecting_metrics?), in the main Ractor only. Asked before the metric of a log call
    # is read, so that a log call without a metric appender costs what it did before metrics were
    # collected. Public on a Logger (see Logger#collecting_metrics?), but not on an appender, which a test
    # can stand in for the processor with.
    #
    # A processor without the method, such as a stand-in for it in a test written for 5.x that answers
    # only #log, collects nothing.
    def collecting_metrics?
      processor = Logger.processor
      processor.respond_to?(:collecting_metrics?) && processor.collecting_metrics?
    end

    # Records the metric of the log entry, when it has one, whether or not the entry is logged: also
    # when its min_duration is not met, or a filter rejects it. `raised` is what the block of a measure
    # call raised, if anything (see #measure_dimensions).
    def record_metric_of(log, raised = nil)
      return unless log.metric && collecting_metrics?

      record_log_metric(log.metric, log.metric_amount, log.duration, measure_dimensions(log.dimensions, raised))
    end

    # Name of the dimension that holds the class of the exception that failed a measured operation, as
    # the semantic conventions of OpenTelemetry name it.
    ERROR_TYPE = "error.type".freeze
    private_constant :ERROR_TYPE

    # Returns [Hash|nil] the dimensions of the metric of a measure call, with ERROR_TYPE added, as the
    # class name of the exception that its block raised, so that the failed calls are a series of their
    # own, unless the dimensions already have one. As they are when its block did not raise, such as for
    # an exception given as `exception:`. The log entry keeps its own dimensions.
    #
    # An exception class without a constant name, such as an anonymous one, or one with a temporary
    # name, is named after its nearest superclass that has one, so that a class made for each call does
    # not add a series each time.
    def measure_dimensions(dimensions, raised)
      return dimensions unless raised
      return dimensions if dimensions && (dimensions.key?(ERROR_TYPE) || dimensions.key?(ERROR_TYPE.to_sym))

      (dimensions || {}).merge(ERROR_TYPE => error_type(raised.class))
    end

    # A constant path, such as "Net::ReadTimeout", which a temporary name (Module#set_temporary_name)
    # never is.
    CONSTANT_PATH = /\A\p{Lu}[\p{Word}]*(?:::\p{Lu}[\p{Word}]*)*\z/
    private_constant :CONSTANT_PATH

    # Returns [String] the constant name of the exception class, or of its nearest superclass that has
    # one. Reads it with Module#name itself, never a `name` that the class defines, which could raise.
    def error_type(klass)
      while klass
        name = Module.instance_method(:name).bind_call(klass)
        return name if name&.match?(CONSTANT_PATH)

        klass = klass.superclass
      end
      "Exception"
    end

    # Records the metric of a log call, whose kind, value, and unit the Log knows (see
    # Log.metric_measurement).
    def record_log_metric(metric, metric_amount, duration, dimensions)
      kind, value, unit = Log.metric_measurement(duration, metric_amount)
      record_metric(kind, metric, value, unit: unit, dimensions: dimensions)
    end

    # Records the metric of a log call below the log level, which logs nothing, while metrics are
    # collected. The one check made below the level, by the level methods and Compatibility#add: only
    # the Hash that #log_internal would extract the arguments from can carry a metric, when it has a
    # :metric key (see Log.metric?), read as #log_internal would (see Log.metric_arguments). A call
    # without one costs a few type checks. A logging block is not called, so a metric it returns is
    # not recorded.
    def record_metric_below_level(message, payload, exception)
      return unless exception.nil?

      arguments = payload.nil? ? message : (payload if message)
      return unless arguments.is_a?(Hash) && Log.metric?(arguments) && collecting_metrics?

      metric, metric_amount, duration, dimensions = Log.metric_arguments(arguments)
      record_log_metric(metric, metric_amount, duration, dimensions) if metric
    end

    # A measure call below the log level, given a Hash that can carry a metric: returns the result of
    # the block, as when no metric is given. While metrics are collected, and when a metric is
    # given, it times the block, or takes the duration given without one, and records the metric,
    # as #measure_internal would. The time is recorded however the block ends, and what it raises is
    # raised again.
    def measure_below_level(message, params, &block)
      return block&.call(params) unless collecting_metrics?

      options = message.is_a?(Hash) && params.respond_to?(:empty?) && params.empty? ? message : params
      return block&.call(params) unless options.is_a?(Hash) && measure_option(options, :metric)

      unless block
        duration = measure_option(options, :duration)
        record_measure_metric(options, duration) if duration
        return
      end

      start  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raised = nil
      begin
        block.call(params)
      rescue Exception => e
        raised = e
        raise
      ensure
        record_measure_metric(options, 1_000.0 * (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start), raised)
      end
    end

    # Records the metric of a measure call that took the duration, in milliseconds, whose block raised
    # `raised`, if anything (see #measure_dimensions). Its options are read once the block has returned,
    # since the block can change them, as #measure_internal does.
    def record_measure_metric(options, duration, raised = nil)
      metric = measure_option(options, :metric)
      return unless metric

      record_log_metric(metric, measure_option(options, :metric_amount), duration,
                        measure_dimensions(measure_option(options, :dimensions), raised))
    end

    # Return the level index for fast comparisons, resolved in the same order as `#level`.
    def level_index
      (@with_level_used && with_level_index) || @level_index || fallback_level_index
    end

    # Level to use when no level has been set for this instance: the global default level.
    def fallback_level
      SemanticLogger.default_level
    end

    # Level index to use when no level has been set for this instance. Unlike
    # `#fallback_level`, it honors `SemanticLogger.silence`.
    def fallback_level_index
      SemanticLogger.default_level_index
    end

    # Level index set for this instance by an enclosing `#with_level` block on the current fiber.
    def with_level_index
      Context.with_level_index(self)
    end

    # Whether to log the supplied message based on the current filter if any
    def filtered?(log)
      return false if @filter.nil?

      @filter.is_a?(Regexp) ? !name_matches_filter?(log.name) : @filter.call(log) != true
    end

    # Whether the name matches the Regexp filter. A name that is not valid in its encoding, or is
    # not ASCII-compatible, which matching raises for, is matched converted to valid UTF-8 (see
    # Utils.encode_utf8_string), since a log call must not raise.
    def name_matches_filter?(name)
      @filter.match?(name)
    rescue ArgumentError, EncodingError
      utf8_name_matches_filter?(Utils.encode_utf8_string(name.to_s))
    end

    # Whether the Regexp filter matches the name, which is valid UTF-8. A Regexp fixed to another
    # encoding, such as one that holds characters outside ASCII written in a source file in
    # ISO-8859-1, cannot match UTF-8 text, so it matches the name in its own encoding: as bytes for
    # a binary Regexp, otherwise converted, with "?" for a character the encoding does not have. A
    # name that it still cannot match, such as for an encoding with no converter from UTF-8, does
    # not match.
    def utf8_name_matches_filter?(name)
      @filter.match?(name)
    rescue ArgumentError, EncodingError
      encoding = @filter.encoding
      begin
        text = encoding == Encoding::BINARY ? name.b : name.encode(encoding, invalid: :replace, undef: :replace)
        @filter.match?(text)
      rescue ArgumentError, EncodingError
        false
      end
    end

    # Ensure minimum log level is met
    def meets_log_level?(log)
      (level_index <= (log.level_index || 0))
    end

    # Build a new Log entry, layering this logger's instance tags on top of the
    # context of the thread, by default the current one.
    def new_log(level, index = nil, thread = Thread.current)
      apply_instance_tags(Log.new(name, level, index, thread))
    end

    # Merge this logger's instance tags into the supplied Log entry.
    #
    # Composition (mirrors the per-logger merge rule proposed in PR #301):
    # - Positional: thread tags first, then this logger's instance tags appended.
    # - Named: instance named tags merged on top of the thread named tags, so on a
    #   key conflict the logger's own identity wins (it is the more specific value).
    # Only this logger's entries are affected; the thread context is left untouched.
    def apply_instance_tags(log)
      unless @instance_tags.empty?
        log.tags = log.tags.empty? ? @instance_tags.dup : log.tags + @instance_tags
      end
      unless @instance_named_tags.empty?
        log.named_tags = log.named_tags.empty? ? @instance_named_tags.dup : log.named_tags.merge(@instance_named_tags)
      end
      log
    end

    # Returns a copy of this logger that permanently carries the supplied tags.
    # Positional (string) and named (Hash) tags may be mixed; they are merged on
    # top of any instance tags this logger already carries.
    def tagged_child(tags)
      positional = @instance_tags.dup
      named      = @instance_named_tags.dup
      tags.flatten.each do |tag|
        case tag
        when Hash
          named = named.merge(tag)
        when nil, ""
          # Ignore blanks for Rails compatibility, matching the block form.
        else
          positional << tag.to_s
        end
      end

      child                     = clone
      child.instance_tags       = positional.freeze
      child.instance_named_tags = named.freeze
      child
    end

    # Log message at the specified level
    def log_internal(level, index, message = nil, payload = nil, exception = nil, &block)
      # Handle variable number of arguments by detecting exception object and payload hash.
      if exception.nil? && payload.nil? && message.respond_to?(:backtrace) && message.respond_to?(:message)
        exception = message
        message   = nil
      elsif exception.nil? && payload.respond_to?(:backtrace) && payload.respond_to?(:message)
        exception = payload
        payload   = nil
      elsif payload && !payload.is_a?(Hash)
        # Joined so that texts in incompatible encodings, such as a UTF-8 message and a binary
        # response body, cannot make the log call raise (see Utils.join_texts).
        message = message.nil? ? payload : Utils.join_texts(message, " -- ", payload)
        payload = nil
      end

      log = new_log(level, index)
      should_log =
        if exception.nil? && payload.nil? && message.is_a?(Hash)
          # All arguments as a hash in the message.
          log.assign(**log.extract_arguments(message))
        elsif exception.nil? && message && payload.is_a?(Hash)
          # Message supplied along with a hash with the remaining arguments.
          log.assign(**log.extract_arguments(payload, message))
        else
          # All fields supplied directly.
          log.assign(message: message, payload: payload, exception: exception)
        end

      # Add result of block to message or payload if not nil
      apply_block_result(log, &block) if block
      record_metric_of(log)

      # Log level may change during assign due to :on_exception_level
      self.log(log) if should_log && should_log?(log)
    end

    # Merge the result of a logging block into the log entry.
    #
    # Zero-arity blocks (e.g. `logger.info { "msg" }` or a zero-arity lambda) are called without
    # arguments. Lambdas enforce their arity, so yielding the log to a zero-arity lambda would
    # raise ArgumentError. Blocks that accept an argument still receive the log so they can read
    # or mutate it.
    #
    # A String result is joined to the message with Utils.join_texts, so that texts in incompatible
    # encodings, such as a UTF-8 message and a binary block result, cannot make the log call raise.
    def apply_block_result(log, &block)
      result = block.arity.zero? ? block.call : block.call(log)
      case result
      when String
        log.message = log.message.nil? ? result : Utils.join_texts(log.message, " -- ", result)
      when Hash
        log.assign_hash(result)
      end
    end

    # Measure the supplied block and log the message
    #
    # The options can hold untrusted data, so an option with a value that is not valid for it is
    # ignored (see Log.argument?) and its default is used instead.
    def measure_internal(level, index, message, params)
      exception = nil
      raised    = nil
      # Single parameter is a hash
      if params.empty? && message.is_a?(Hash)
        params  = message
        message = nil
      end
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        if block_given?
          if (silence_level = measure_silence_level(params))
            silence(silence_level) { yield(params) }
          else
            yield(params)
          end
        end
      rescue Exception => e
        exception = e
        raised    = e
      ensure
        # Must use ensure block otherwise a `return` in the yield above will skip the log entry
        log = new_log(level, index)
        # Only an Exception, since it is re-raised below
        exception ||= params[:exception] if params[:exception].is_a?(Exception)
        message     = measure_option(params, :message) || message
        duration    =
          if block_given?
            1_000.0 * (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start)
          else
            measure_option(params, :duration) ||
              raise("Mandatory block missing when :duration option is not supplied")
          end

        # Extract options after block completes so that block can modify any of the options
        payload = params[:payload]

        # May return false due to elastic logging
        should_log = log.assign(
          message:            message,
          payload:            payload,
          min_duration:       measure_option(params, :min_duration) || 0.0,
          exception:          exception,
          metric:             measure_option(params, :metric),
          metric_amount:      measure_option(params, :metric_amount),
          dimensions:         measure_option(params, :dimensions),
          duration:           duration,
          log_exception:      measure_option(params, :log_exception) || :partial,
          on_exception_level: measure_option(params, :on_exception_level),
          call_site:          measure_option(params, :call_site)
        )
        record_metric_of(log, raised)

        # Log level may change during assign due to :on_exception_level
        self.log(log) if should_log && should_log?(log)
        raise exception if exception
      end
    end

    # Returns the value of the measure option that is also a log argument, or nil when it is not
    # supplied or its value is not valid for that argument.
    def measure_option(params, key)
      value = params[key]
      value if Log.argument?(key, value)
    end

    # Returns the level to silence other log messages to within a measure block, or nil when none
    # is supplied or it is not a valid level.
    def measure_silence_level(params)
      silence_level = params[:silence]
      # In case someone accidentally sets `silence: true` instead of `silence: :error`
      silence_level = :error if silence_level == true
      silence_level if Levels.valid?(silence_level)
    end
  end
end
