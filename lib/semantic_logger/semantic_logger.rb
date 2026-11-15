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

    cached_logger(klass)
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

  # Sets the level at and above which each log entry records where it was logged: the file, line,
  # and method of the code that made the log call (see Log#call_site). The JSON and text formatters
  # then write the method next to the file name and line number.
  #
  # Unlike backtrace_level, it reads only the frames of the stack up to the code that made the log
  # call, which costs about a microsecond per entry however deep the stack is, instead of building
  # the whole backtrace.
  #
  # Parameters
  #   level: [Symbol|nil]
  #     :trace, :debug, :info, :warn, :error, or :fatal.
  #     nil: Do not record where entries were logged.
  #     Default: nil
  #
  # Example:
  #   SemanticLogger.call_site_level = :info
  def self.call_site_level=(level)
    # For performance reasons pre-calculate the level index
    index                  = Levels.index(level)
    @call_site_level_index = index.nil? ? 65_535 : index
    @call_site_level       = index.nil? ? nil : Levels.level(index)
  end

  # Returns the level at and above which each log entry records where it was logged, or nil when
  # it is not recorded.
  def self.call_site_level
    @call_site_level
  end

  # Returns the call site level index
  # For internal use only
  def self.call_site_level_index
    @call_site_level_index
  end

  # Sets the paths, or parts of paths, of code that logs on behalf of its caller, such as an
  # application's own logging helper. A frame in a file whose path includes one of them is skipped
  # when recording where an entry was logged, so that the entry shows the code that called the
  # helper. Semantic Logger's own frames are always skipped.
  #
  # Parameters
  #   paths: [Array<String>|nil]
  #     Each matches any file whose path includes it, such as "app/lib/audit_log.rb", or
  #     "/my_logging_gem/" for every file of a gem.
  #     nil: Skip only Semantic Logger's own frames.
  #     Default: []
  #
  # Example:
  #   SemanticLogger.call_site_skip_paths = ["app/lib/audit_log.rb"]
  def self.call_site_skip_paths=(paths)
    paths = [] if paths.nil?
    valid = paths.is_a?(Array) && paths.all? { |path| path.is_a?(String) && !path.empty? }
    raise(ArgumentError, "call_site_skip_paths must be an Array of non-empty Strings: #{paths.inspect}") unless valid

    # Frozen copies, leaving the Strings supplied as they are, so that code in any Ractor can read them.
    @call_site_skip_paths = Utils.make_shareable(paths.map(&:-@).freeze)
  end

  # Returns [Array<String>] the paths, or parts of paths, whose frames are skipped when recording
  # where an entry was logged.
  def self.call_site_skip_paths
    @call_site_skip_paths
  end

  # Sets the application's backtrace cleaner, which leaves out or shortens the lines of the
  # backtraces that the text and JSON formatters log, such as `Rails.backtrace_cleaner`.
  #
  # Parameters
  #   cleaner: [Object|nil]
  #     An object that responds to `#clean`, as ActiveSupport::BacktraceCleaner does, or to `#call`,
  #     such as a Proc. It is given each exception's backtrace as an Array of Strings, and returns
  #     the lines to log. When it leaves out every line, or raises, the full backtrace is logged,
  #     and an error it raises is reported to the internal logger.
  #     It is called on the appender threads, so it must be thread safe.
  #     nil: Do not clean backtraces.
  #     Default: nil
  #
  # The `:default`, `:color`, `:pattern`, `:syslog`, `:json`, and `:fluentd` formatters use it
  # unless given `backtrace_cleaner: false`. Other formatters only use it when given
  # `backtrace_cleaner: true`. Appenders that send the exception itself, such as error services,
  # are not affected.
  #
  # Example:
  #   SemanticLogger.backtrace_cleaner = Rails.backtrace_cleaner
  def self.backtrace_cleaner=(cleaner)
    # Compared by identity, since a cleaner, such as a test double, need not define #nil?.
    BacktraceCleaning.validate!(cleaner, expected: "nil or a backtrace cleaner") unless nil.equal?(cleaner)

    @backtrace_cleaner = cleaner
  end

  # Returns the application's backtrace cleaner, or nil when there is none.
  def self.backtrace_cleaner
    @backtrace_cleaner
  end

  # Sets the keys whose values are replaced with "[FILTERED]" in every log entry, such as
  # passwords and access tokens, before any appender writes it.
  #
  # Parameters
  #   keys: [Array|Regexp|Object|nil]
  #     Array: Symbols and Strings, each matching any key whose name contains it, ignoring case,
  #       as in Rails' `config.filter_parameters`, and Regexps.
  #     Regexp: Matches the names of the sensitive keys.
  #     An object that responds to `#filter_param`, such as ActiveSupport::ParameterFilter, which
  #       is asked about each key name: `filter_param(name, nil)` returns nil when the key is not
  #       sensitive, and otherwise the value that replaces the key's value.
  #     An object that responds to `#call`, such as a Proc, given each key name, which returns
  #       whether the key is sensitive.
  #     nil: Do not redact.
  #     Default: nil
  #
  # The keys of the payload, named tags, context, and metric dimensions of each entry are matched,
  # at any depth, both as written and in snake_case, so that "X-Api-Key" and "apiKey" are also
  # matched as "x_api_key" and "api_key". The message, tags, and exception are not changed.
  #
  # Each entry is redacted once, on the thread that writes it to the appenders, before any of them
  # writes it, so the keys must be thread safe. `on_log` subscribers and logger filters run before,
  # on the thread that logs the entry, and receive it as it was logged. The application's own
  # Hashes are never changed: the entry gets a copy.
  #
  # The keys are read when they are assigned, so changing an Array of them afterwards has no effect:
  # assign them again instead.
  #
  # When an entry cannot be redacted, for example because the keys raise an error, the field is
  # replaced with `{redaction_failed: "ErrorClass"}`, and the error is reported to the internal
  # logger.
  #
  # Example:
  #   SemanticLogger.sensitive_keys = [:password, :secret, :token, :authorization]
  #
  # Example, with the parameters that Rails filters, except its Proc filters, which change a value
  # rather than name a key (rails_semantic_logger does this once the application has initialized):
  #   filters = Rails.application.config.filter_parameters.reject { |filter| filter.respond_to?(:call) }
  #   SemanticLogger.sensitive_keys = ActiveSupport::ParameterFilter.new(filters)
  def self.sensitive_keys=(keys)
    # Compared by identity, since the keys, such as a test double, need not define #nil?.
    @redactor = nil.equal?(keys) ? nil : Redactor.new(keys)
  end

  # Returns the sensitive keys, as supplied to .sensitive_keys=, or nil when there are none.
  def self.sensitive_keys
    @redactor&.sensitive_keys
  end

  # Internal: Returns [SemanticLogger::Redactor] the redactor for the sensitive keys, which each
  # entry is asked to redact itself with before it is written (see Appenders#log), or nil when
  # there are no sensitive keys.
  def self.redactor
    @redactor
  end

  # Returns [String] name of this host for logging purposes
  # Note: Not all appenders use `host`
  def self.host
    @host
  end

  # Override the default host name, which is this machine's host name. Set it to nil to go back to
  # the default.
  #
  # The host, application, and environment are stored as frozen copies, so that code in any Ractor
  # can read them. The value supplied is left as it is.
  def self.host=(host)
    @host = Utils.make_shareable(host || Socket.gethostname.force_encoding("UTF-8"), copy: true)
  end

  # Returns [String] name of this application for logging purposes
  # Note: Not all appenders use `application`
  def self.application
    @application
  end

  # Override the default application
  def self.application=(application)
    @application = Utils.make_shareable(application, copy: true)
  end

  # Returns [String] name of this environment for logging purposes
  # Note: Not all appenders use `environment`
  def self.environment
    @environment
  end

  # Override the default environment
  def self.environment=(environment)
    @environment = Utils.make_shareable(environment, copy: true)
  end

  self.host        = nil
  self.application = ENV["SEMANTIC_LOGGER_APP"] || "Semantic Logger"
  self.environment = ENV["SEMANTIC_LOGGER_ENV"] || ENV["RAILS_ENV"] || ENV.fetch("RACK_ENV", nil)

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
    # And the thread that receives the entries logged in other Ractors (Ruby 4.0 and later).
    RactorReceiver.start if RactorSupport.enabled?
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
  #
  #  On Ruby 4.0 and later, in the main Ractor, the entries already sent from other Ractors are
  #  written first. In another Ractor, it waits until the main Ractor has written that Ractor's
  #  entries and flushed the appenders.
  def self.flush
    return Logger.processor.flush if !RactorSupport.enabled? || RactorSupport.other_ractor?

    RactorReceiver.flush
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
    RactorReceiver.reopen if RactorSupport.enabled?
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
  # Useful for capturing appender specific context information. Keep an object that is for an
  # appender of your own with `log.capture`, and data to be logged with `log.set_context`.
  #
  #  Parameters
  #    object: [Object | Proc]
  #      [Proc] the block to call.
  #      [Object] any object on which to call #call.
  #
  # Example:
  #   SemanticLogger.on_log do |log|
  #     log.capture(:honeybadger, Honeybadger.get_context)
  #   end
  #
  # Example:
  #   module CaptureContext
  #     def call(log)
  #       log.capture(:honeybadger, Honeybadger.get_context)
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
  def self.fast_tag(tag, &)
    return yield if tag.nil? || tag == ""

    Context.fast_tag(tag, &)
  end

  # Add the tags or named tags to the list of tags to log for this fiber whilst the supplied block is active.
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

    # The rest Array is this call's own, so Context may keep it.
    Context.tagged(tags, &)
  end

  # Returns a copy of the [Array] of [String] tags currently active for this fiber.
  # Returns an empty Array if no tags are set.
  def self.tags
    Context.tags
  end

  # Add tags to the current scope
  #
  # Note:
  # - This method does not flatten the array or remove any empty elements, or duplicates
  #   since the performance penalty is excessive.
  # - To get the flattening behavior use the slower api:
  #     `logger.push_tags`
  def self.push_tags(*tags)
    Context.push_tags(tags)
    tags
  end

  # Remove specified number of tags from the current tag list
  def self.pop_tags(quantity = 1)
    Context.pop_tags(quantity)
  end

  # Returns [SemanticLogger::Context] a frozen snapshot of the logging context of the current fiber:
  # its tags, named tags, and silence level (see .silence).
  #
  # The context belongs to the current fiber, so a thread or fiber started inside a `tagged` block
  # does not have its tags. Hand the context over with .with_context:
  #
  #   context = SemanticLogger.context
  #   Thread.new do
  #     SemanticLogger.with_context(context) do
  #       logger.info("Logged with the same tags")
  #     end
  #   end
  #
  # The context does not include the levels set by a logger's #with_level, which, like Ruby's
  # Logger#with_level, apply only to the fiber that set them.
  def self.context
    Context.current
  end

  # Runs the block with the supplied context, from .context, as the logging context of the current
  # fiber. Within the block the fiber has exactly the tags, named tags, and silence level of that
  # context, in place of its own, which are restored when the block exits.
  #
  # Returns the result of the block.
  def self.with_context(context, &)
    Context.use(context, &)
  end

  # :nodoc
  def self.named_tagged(hash, &)
    return yield if hash.nil? || hash.empty?
    raise(ArgumentError, "#named_tagged only accepts named parameters (Hash)") unless hash.is_a?(Hash)

    Context.named_tagged(hash, &)
  end

  # Returns [Hash] a copy of the named tags currently active for this fiber.
  def self.named_tags
    Context.named_tags
  end

  def self.push_named_tags(hash)
    Context.push_named_tags(hash)
    hash
  end

  def self.pop_named_tags(quantity = 1)
    Context.pop_named_tags(quantity)
  end

  # Silence noisy log levels by changing the default_level within the block
  #
  # This setting only applies to the current fiber: every thread, and every fiber of a fiber
  # scheduler such as Async, has its own.
  #
  # Threads and fibers started within the block are not affected by this setting
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
  def self.silence(new_level = :error, &)
    Context.silence(Levels.index(new_level), &)
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
  #                                 async thread report their queue_size and
  #                                 processed/dropped/failed counts; appenders that log
  #                                 inline report `async: false`.
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

  # Returns [true|false] whether log messages are dropped instead of blocking
  # when the main pipeline queue is full.
  def self.non_blocking?
    Logger.processor.non_blocking?
  end

  # Drop log messages instead of blocking the calling thread when the main
  # pipeline queue is full.
  def self.non_blocking=(non_blocking)
    Logger.processor.non_blocking = non_blocking
  end

  def self.default_level_index
    Context.silence_index || @default_level_index
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
  @backtrace_cleaner     = nil
  @redactor              = nil
  @sync                  = false
  @cache_loggers         = false
  @logger_cache          = nil

  # Do not record where entries were logged, and skip only Semantic Logger's own frames.
  self.call_site_level      = nil
  self.call_site_skip_paths = nil

  # Lazily initialized thread-safe cache of one Logger per Class/Module.
  def self.logger_cache
    @logger_cache ||= Concurrent::Map.new
  end
  private_class_method :logger_cache

  # Returns the cached Logger for the Class or Module.
  #
  # A Ractor other than the main one cannot use the main Ractor's cache, or its loggers, so it has a
  # cache of its own (experimental, Ruby 4.0 and later).
  def self.cached_logger(klass)
    if RactorSupport.other_ractor?
      cache = ::Ractor.store_if_absent(:semantic_logger_logger_cache) { {} }
      return cache[klass] ||= Logger.new(klass)
    end

    logger_cache.compute_if_absent(klass) { Logger.new(klass) }
  end
  private_class_method :cached_logger

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
    autoload :RSpec,             "semantic_logger/test/rspec"
  end

  if defined?(JRuby)
    module JRuby
      autoload :GarbageCollectionLogger, "semantic_logger/jruby/garbage_collection_logger"
    end
  end
  # @formatter:on
end
