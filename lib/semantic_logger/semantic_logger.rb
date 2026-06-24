require "socket"

module SemanticLogger
  # Logging levels in order of most detailed to most severe
  LEVELS = Levels::LEVELS

  # Return a logger for the supplied class or class_name.
  #
  # When `SemanticLogger.cache_loggers` is enabled (opt-in, default off) and a
  # Class or Module is supplied, the same Logger instance is returned for every
  # call with that class. This makes it possible to obtain a logger once and
  # later change its level (or filter) and have every holder of that logger see
  # the change.
  #
  # A String is always given its own new Logger instance, even when caching is
  # enabled: callers that pass a string typically want an independent logger
  # (for example to set a different level per call site). Anonymous classes
  # (those with no `name`) are never cached, to avoid pinning short-lived
  # dynamically created classes in memory.
  def self.[](klass)
    return Logger.new(klass) if !@cache_loggers || klass.is_a?(String) || klass.name.nil?

    logger_cache.compute_if_absent(klass) { Logger.new(klass) }
  end

  # Whether `SemanticLogger[Class]` returns a shared, cached Logger instance per
  # class. Disabled by default. Strings are never cached (see #[]).
  def self.cache_loggers=(cache_loggers)
    @cache_loggers = cache_loggers
    clear_logger_cache unless cache_loggers
  end

  # Returns whether logger caching is enabled.
  def self.cache_loggers?
    @cache_loggers
  end

  # Discard all cached loggers so that subsequent `SemanticLogger[Class]` calls
  # build fresh instances. Primarily useful in tests, or after redefining a
  # class that was previously cached.
  def self.clear_logger_cache
    @logger_cache&.clear
  end

  # Sets the global default log level
  def self.default_level=(level)
    @default_level = level
    # For performance reasons pre-calculate the level index
    @default_level_index = Levels.index(level)
  end

  # Returns the global default log level
  def self.default_level
    @default_level
  end

  # Sets the level at which backtraces should be captured
  # for every log message.
  #
  # By enabling backtrace capture the filename and line number of where
  # message was logged can be written to the log file. Additionally, the backtrace
  # can be forwarded to error management services such as Bugsnag.
  #
  # Warning:
  #   Capturing backtraces is very expensive and should not be done all
  #   the time. It is recommended to run it at :error level in production.
  def self.backtrace_level=(level)
    @backtrace_level = level
    # For performance reasons pre-calculate the level index
    @backtrace_level_index = level.nil? ? 65_535 : Levels.index(level)
  end

  # Returns the current backtrace level
  def self.backtrace_level
    @backtrace_level
  end

  # Returns the current backtrace level index
  # For internal use only
  def self.backtrace_level_index
    @backtrace_level_index
  end

  # Returns [String] name of this host for logging purposes
  # Note: Not all appenders use `host`
  def self.host
    @host ||= Socket.gethostname.force_encoding("UTF-8")
  end

  # Override the default host name
  def self.host=(host)
    @host = host
  end

  # Returns [String] name of this application for logging purposes
  # Note: Not all appenders use `application`
  def self.application
    @application
  end

  # Override the default application
  def self.application=(application)
    @application = application
  end

  # Returns [String] name of this environment for logging purposes
  # Note: Not all appenders use `environment`
  def self.environment
    @environment
  end

  # Override the default environment
  def self.environment=(environment)
    @environment = environment
  end

  @application = ENV["SEMANTIC_LOGGER_APP"] || "Semantic Logger"
  @environment = ENV["SEMANTIC_LOGGER_ENV"] || ENV["RAILS_ENV"] || ENV.fetch("RACK_ENV", nil)

  # Add a new logging appender as a new destination for all log messages
  # emitted from Semantic Logger
  #
  # Appenders will be written to in the order that they are added
  #
  # If a block is supplied then it will be used to customize the format
  # of the messages sent to that appender. See SemanticLogger::Logger.new for
  # more information on custom formatters
  #
  # Parameters
  #   file_name: [String]
  #     File name to write log messages to.
  #
  #   Or,
  #   io: [IO]
  #     An IO Stream to log to.
  #     For example $stdout, $stderr, etc.
  #
  #   Or,
  #   appender: [Symbol|SemanticLogger::Subscriber]
  #     A symbol identifying the appender to create.
  #     For example:
  #       :bugsnag, :elasticsearch, :graylog, :http, :mongodb, :new_relic, :splunk_http, :syslog, :wrapper
  #          Or,
  #     An instance of an appender derived from SemanticLogger::Subscriber
  #     For example:
  #       SemanticLogger::Appender::Http.new(url: 'http://localhost:8088/path')
  #
  #   Or,
  #   logger: [Logger|Log4r]
  #     An instance of a Logger or a Log4r logger.
  #
  #   level: [:trace | :debug | :info | :warn | :error | :fatal]
  #     Override the log level for this appender.
  #     Default: SemanticLogger.default_level
  #
  #   formatter: [Symbol|Object|Proc]
  #     Any of the following symbol values: :default, :color, :json, :logfmt, etc...
  #       Or,
  #     An instance of a class that implements #call
  #       Or,
  #     A Proc to be used to format the output from this appender
  #     Default: :default
  #
  #   filter: [Regexp|Proc]
  #     RegExp: Only include log messages where the class name matches the supplied.
  #     regular expression. All other messages will be ignored.
  #     Proc: Only include log messages where the supplied Proc returns true
  #           The Proc must return true or false.
  #
  # Examples:
  #
  #   # Send all logging output to Standard Out (Screen)
  #   SemanticLogger.add_appender(io: $stdout)
  #
  #   # Send all logging output to a file
  #   SemanticLogger.add_appender(file_name: 'logfile.log')
  #
  #   # Send all logging output to a file and only :info and above to standard output
  #   SemanticLogger.add_appender(file_name: 'logfile.log')
  #   SemanticLogger.add_appender(io: $stdout, level: :info)
  #
  # Log to log4r, Logger, etc.:
  #
  #   # Send Semantic logging output to an existing logger
  #   require 'logger'
  #   require 'semantic_logger'
  #
  #   # Built-in Ruby logger
  #   log = Logger.new($stdout)
  #   log.level = Logger::DEBUG
  #
  #   SemanticLogger.default_level = :debug
  #   SemanticLogger.add_appender(logger: log)
  #
  #   logger = SemanticLogger['Example']
  #   logger.info "Hello World"
  #   logger.debug("Login time", user: 'Joe', duration: 100, ip_address: '127.0.0.1')
  def self.add_appender(**args, &)
    appender = appenders.add(**args, &)
    # Start appender thread if it is not already running
    Logger.processor.start
    appender
  end

  # Remove an existing appender
  # Currently only supports appender instances
  def self.remove_appender(appender)
    return unless appender

    appenders.delete(appender)
    appender.close
  end

  # Clear out all previously registered appenders
  def self.clear_appenders!
    Logger.processor.close
  end

  # Returns [SemanticLogger::Subscriber] a copy of the list of active
  # appenders for debugging etc.
  # Use SemanticLogger.add_appender and SemanticLogger.remove_appender
  # to manipulate the active appenders list
  def self.appenders
    Logger.processor.appenders
  end

  # Flush all queued log entries disk, database, etc.
  #  All queued log messages are written and then each appender is flushed in turn.
  def self.flush
    Logger.processor.flush
  end

  # Close all appenders and flush any outstanding messages.
  def self.close
    Logger.processor.close
  end

  # Re-open any open file handles etc. to resources.
  #
  # Called automatically in the child process after a fork (see reopen_on_fork?),
  # and may also be called manually.
  #
  # To avoid reopening twice after a single fork (for example when the automatic
  # fork hook and a framework's `after_fork` callback both fire), reopen is a no-op
  # if it has already run in the current process. Pass `force: true` to override
  # this guard and reopen unconditionally, for example when re-opening file handles
  # in the same process after an external log rotation.
  #
  # Note:
  #   Not all appender's implement reopen.
  #   Check the code for each appender you are using before relying on this behavior.
  def self.reopen(force: false)
    return if !force && @reopened_pid == ::Process.pid

    Logger.processor.reopen
    @reopened_pid = ::Process.pid
  end

  # Whether appenders are automatically reopened in the child process after a fork.
  #
  # Enabled by default. A `Process._fork` hook (Ruby 3.1+) calls SemanticLogger.reopen
  # in the child after `fork`, `Process.daemon`, `IO.popen`, `Kernel#system`, and
  # backticks, so framework specific `after_fork` hooks (Puma, Unicorn, Resque,
  # Spring, etc.) are no longer required.
  def self.reopen_on_fork?
    @reopen_on_fork != false
  end

  # Enable or disable automatic reopening of appenders after a fork.
  #
  #   # Opt out of the automatic behavior and manage reopen manually:
  #   SemanticLogger.reopen_on_fork = false
  def self.reopen_on_fork=(reopen_on_fork)
    @reopen_on_fork = reopen_on_fork
  end

  # Supply a callback to be called whenever a log entry is created.
  # Useful for capturing appender specific context information.
  #
  #  Parameters
  #    object: [Object | Proc]
  #      [Proc] the block to call.
  #      [Object] any object on which to call #call.
  #
  # Example:
  #   SemanticLogger.on_log do |log|
  #     log.set_context(:honeybadger, Honeybadger.get_context)
  #   end
  #
  # Example:
  #   module CaptureContext
  #     def call(log)
  #       log.set_context(:honeybadger, Honeybadger.get_context)
  #     end
  #   end
  #   SemanticLogger.on_log(CaptureContext)
  #
  # Note:
  # * This callback is called within the thread of the application making the logging call.
  # * If these callbacks are slow they will slow down the application.
  def self.on_log(object = nil, &)
    Logger.subscribe(object, &)
  end

  # Add signal handlers for Semantic Logger
  #
  # Two signal handlers will be registered by default:
  #
  # 1. Changing the log_level:
  #
  #   The log level can be changed without restarting the process by sending the
  #   log_level_signal, which by default is 'USR2'
  #
  #   When the log_level_signal is raised on this process, the global default log level
  #   rotates through the following log levels in the following order, starting
  #   from the current global default level:
  #     :fatal, :error, :warn, :info, :debug, :trace
  #
  #   If the current level is :trace it wraps around back to :fatal
  #
  # 2. Logging a Ruby thread dump
  #
  #   When the signal is raised on this process, Semantic Logger will write the list
  #   of threads to the log file, along with their back-traces when available
  #
  #   For JRuby users this thread dump differs form the standard QUIT triggered
  #   Java thread dump which includes system threads and Java stack traces.
  #
  #   It is recommended to name any threads you create in the application, by
  #   calling the following from within the thread itself:
  #      Thread.current.name = 'My Worker'
  #
  # Also adds JRuby Garbage collection logging so that any garbage collections
  # that exceed the time threshold will be logged. Default: 100 ms
  # Currently only supported when running JRuby
  #
  # Note:
  #   To only register one of the signal handlers, set the other to nil
  #   Set gc_log_microseconds to nil to not enable JRuby Garbage collections
  def self.add_signal_handler(log_level_signal = "USR2", thread_dump_signal = "TTIN", gc_log_microseconds = 100_000)
    if log_level_signal
      Signal.trap(log_level_signal) do
        current_level_index = LEVELS.find_index(default_level)
        new_level_index = current_level_index == 0 ? LEVELS.size - 1 : current_level_index - 1
        new_level = LEVELS[new_level_index]
        self.default_level = new_level
        self["SemanticLogger"].warn "Changed global default log level to #{new_level.inspect}"
      end
    end

    if thread_dump_signal
      Signal.trap(thread_dump_signal) do
        logger = SemanticLogger["Thread Dump"]
        Thread.list.each do |thread|
          # MRI re-uses the main thread for signals, JRuby uses `SIGTTIN handler` thread.
          next if defined?(JRuby) && (thread == Thread.current)

          logger.backtrace(thread: thread)
        end
      end
    end

    if gc_log_microseconds && defined?(JRuby)
      listener = SemanticLogger::JRuby::GarbageCollectionLogger.new(gc_log_microseconds)
      Java::JavaLangManagement::ManagementFactory.getGarbageCollectorMXBeans.each do |gcbean|
        gcbean.add_notification_listener(listener, nil, nil)
      end
    end

    true
  end

  # If the tag being supplied is definitely a string then this fast
  # tag api can be used for short lived tags
  def self.fast_tag(tag)
    return yield if tag.nil? || tag == ""

    t = Thread.current[:semantic_logger_tags] ||= []
    begin
      t << tag
      yield
    ensure
      t.pop
    end
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
  # - Tags should be a list without any empty values, or contain any array.
  #   - `logger.tagged` is a slower api that will flatten the example below:
  #     `logger.tagged([['first', nil], nil, ['more'], 'other'])`
  #   to the equivalent of:
  #     `logger.tagged('first', 'more', 'other')`
  def self.tagged(*tags, &)
    return yield if tags.empty?

    # Allow named tags to be passed into the logger
    if tags.size == 1
      tag = tags[0]
      return tag.is_a?(Hash) ? named_tagged(tag, &) : fast_tag(tag, &)
    end

    begin
      push_tags(*tags)
      yield
    ensure
      pop_tags(tags.size)
    end
  end

  # Returns a copy of the [Array] of [String] tags currently active for this thread
  # Returns nil if no tags are set
  def self.tags
    # Since tags are stored on a per thread basis this list is thread-safe
    t = Thread.current[:semantic_logger_tags]
    t.nil? ? [] : t.clone
  end

  # Add tags to the current scope
  #
  # Note:
  # - This method does not flatten the array or remove any empty elements, or duplicates
  #   since the performance penalty is excessive.
  # - To get the flattening behavior use the slower api:
  #     `logger.push_tags`
  def self.push_tags(*tags)
    (Thread.current[:semantic_logger_tags] ||= []).concat(tags)
    tags
  end

  # Remove specified number of tags from the current tag list
  def self.pop_tags(quantity = 1)
    t = Thread.current[:semantic_logger_tags]
    t&.pop(quantity)
  end

  # :nodoc
  def self.named_tagged(hash)
    return yield if hash.nil? || hash.empty?
    raise(ArgumentError, "#named_tagged only accepts named parameters (Hash)") unless hash.is_a?(Hash)

    begin
      push_named_tags(hash)
      yield
    ensure
      pop_named_tags
    end
  end

  # Returns [Hash] a copy of the named tags currently active for this thread.
  def self.named_tags
    if (list = Thread.current[:semantic_logger_named_tags]) && !list.empty?
      if list.size > 1
        list.reduce({}) { |sum, h| sum.merge(h) }
      else
        list.first.clone
      end
    else
      {}
    end
  end

  def self.push_named_tags(hash)
    (Thread.current[:semantic_logger_named_tags] ||= []) << hash
    hash
  end

  def self.pop_named_tags(quantity = 1)
    t = Thread.current[:semantic_logger_named_tags]
    t&.pop(quantity)
  end

  # Silence noisy log levels by changing the default_level within the block
  #
  # This setting is thread-safe and only applies to the current thread
  #
  # Any threads spawned within the block will not be affected by this setting
  #
  # #silence can be used to both raise and lower the log level within
  # the supplied block.
  #
  # Example:
  #
  #   # Perform trace level logging within the block when the default is higher
  #   SemanticLogger.default_level = :info
  #
  #   logger.debug 'this will _not_ be logged'
  #
  #   SemanticLogger.silence(:trace) do
  #     logger.debug "this will be logged"
  #   end
  #
  # Parameters
  #   new_level
  #     The new log level to apply within the block
  #     Default: :error
  #
  # Example:
  #   # Silence all logging for this thread below :error level
  #   SemanticLogger.silence do
  #     logger.info "this will _not_ be logged"
  #     logger.warn "this neither"
  #     logger.error "but errors will be logged"
  #   end
  #
  # Note:
  #   #silence does not affect any loggers which have had their log level set
  #   explicitly. I.e. That do not rely on the global default level
  def self.silence(new_level = :error)
    current_index                            = Thread.current[:semantic_logger_silence]
    Thread.current[:semantic_logger_silence] = Levels.index(new_level)
    yield
  ensure
    Thread.current[:semantic_logger_silence] = current_index
  end

  # Returns [Integer] the number of log entries waiting to be written to the appenders.
  #
  # When this number grows it is because the logging appender thread is not
  # able to write to the appenders fast enough. Either reduce the amount of
  # logging, increase the log level, reduce the number of appenders, or
  # look into speeding up the appenders themselves
  def self.queue_size
    Logger.processor.queue.size
  end

  # Returns [Hash] operational statistics for the logging pipeline.
  #
  # Useful for exporting Semantic Logger's own health to a monitoring system such as
  # Prometheus, statsd, etc. The returned Hash contains:
  #
  #   queue_size:     [Integer] Number of log messages waiting on the main pipeline queue.
  #   capped:         [Boolean] Whether the main queue has a maximum size.
  #   max_queue_size: [Integer] Maximum queue size, or nil when uncapped.
  #   thread_active:  [Boolean] Whether the main pipeline thread is running.
  #   processed:      [Integer] Cumulative number of log messages processed since startup.
  #   dropped:        [Integer] Cumulative number of log messages dropped at the main queue.
  #   appenders:      [Array<Hash>] Per-appender statistics. Appenders that run their own
  #                                 async thread report their queue_size and processed/dropped
  #                                 counts; appenders that log inline report `async: false`.
  #
  # All counters are cumulative since process startup. They are thread-safe to read and
  # are maintained without adding any locking to the logging hot path.
  def self.stats
    Logger.processor.stats
  end

  # Returns the check_interval which is the number of messages between checks
  # to determine if the appender thread is falling behind.
  def self.lag_check_interval
    Logger.processor.lag_check_interval
  end

  # Set the check_interval which is the number of messages between checks
  # to determine if the appender thread is falling behind.
  def self.lag_check_interval=(lag_check_interval)
    Logger.processor.lag_check_interval = lag_check_interval
  end

  # Returns the amount of time in seconds
  # to determine if the appender thread is falling behind.
  def self.lag_threshold_s
    Logger.processor.lag_threshold_s
  end

  def self.default_level_index
    Thread.current[:semantic_logger_silence] || @default_level_index
  end

  # Run Semantic Logger in Synchronous mode.
  #
  # I.e. Instead of logging messages in a separate thread for better performance,
  # log them using the current thread.
  def self.sync!
    Logger.sync!
  end

  # Running in synchronous mode?
  def self.sync?
    Logger.sync?
  end

  # Initial default Level for all new instances of SemanticLogger::Logger
  @default_level         = :info
  @default_level_index   = Levels.index(@default_level)
  @backtrace_level       = :error
  @backtrace_level_index = Levels.index(@backtrace_level)
  @sync                  = false
  @cache_loggers         = false
  @logger_cache          = nil

  # Lazily initialized thread-safe cache of one Logger per Class/Module.
  def self.logger_cache
    @logger_cache ||= Concurrent::Map.new
  end
  private_class_method :logger_cache

  # @formatter:off
  module Metric
    autoload :NewRelic,          "semantic_logger/metric/new_relic"
    autoload :Signalfx,          "semantic_logger/metric/signalfx"
    autoload :Statsd,            "semantic_logger/metric/statsd"
  end

  module Reporters
    autoload :Minitest,          "semantic_logger/reporters/minitest"
  end

  module Test
    autoload :CaptureLogEvents,  "semantic_logger/test/capture_log_events"
    autoload :Minitest,          "semantic_logger/test/minitest"
  end

  if defined?(JRuby)
    module JRuby
      autoload :GarbageCollectionLogger, "semantic_logger/jruby/garbage_collection_logger"
    end
  end
  # @formatter:on
end
