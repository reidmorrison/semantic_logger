---
layout: default
---

## Programming Guide
{:.no_toc}

**Contents**

* TOC
{:toc}

This guide covers the logging API: how to get a logger, and everything you can do with it. It builds
up from the simplest log call to more advanced features further down, so you can read it top to
bottom or jump to the part you need.

It assumes Semantic Logger is already installed with at least one appender (a destination such as the
screen or a file). If not, start with the [quick start](index.html#quick-start), then come back here.
For configuring the library itself (log levels, formatters, destinations), see
[Configuration](config.html).

Every example below uses a `logger` obtained in Step 1.

## Step 1: Get a logger

Create one logger per class, passing the class itself:

~~~ruby
logger = SemanticLogger[MyClass]
~~~

When there is no class, for example in a script, pass a name instead:

~~~ruby
logger = SemanticLogger["MyApp"]
~~~

The class or name you supply is attached to every entry that logger writes, so entries from different
parts of the application stay easy to tell apart. Use one logger per class so each entry identifies
where it came from.

### The Loggable mixin (recommended)

Rather than creating a logger by hand in every class, include `SemanticLogger::Loggable`. It adds a
`logger` method to both the class and its instances, already named for the class:

~~~ruby
class Supplier
  include SemanticLogger::Loggable

  def self.some_class_method
    logger.debug("Accessible from class methods")
  end

  def call_supplier
    logger.debug("Accessible from instance methods")
  end
end
~~~

Every entry is identified as coming from `Supplier`:

~~~
2012-08-30 15:37:29.474 I [48308:main] Supplier -- Accessible from instance methods
~~~

By default `SemanticLogger[...]` returns a brand new logger on each call. To share a single logger
per class instead, enable [logger caching](config.html#caching-loggers).

## Step 2: Log a message

Semantic Logger supports the standard Ruby and Rails logger API, so existing code keeps working:

~~~ruby
logger.info("Hello World")
~~~

There is one method per level. The levels, from the most detail to the least, are:

    :trace  :debug  :info  :warn  :error  :fatal

~~~ruby
logger.trace("Low level detail, such as data sent over a socket")
logger.debug("Information to aid problem determination")
logger.info("Something normal happened, such as a request received")
logger.warn("Something unexpected, but handled")
logger.error("An error occurred during processing")
logger.fatal("Something really bad happened")
~~~

The active level acts as a threshold. At the default of `:info`, the `info`, `warn`, `error`, and
`fatal` calls are written while `debug` and `trace` are skipped. `:trace` is the most detailed level,
useful for tracing low level calls such as data exchanged with an external service. Setting the
global default level, and changing it at runtime, is covered in
[Configuration](config.html#default-log-level).

To check whether a level is active (for example before doing expensive work):

~~~ruby
logger.info? # => true when :info and above are being logged
~~~

## Step 3: Add structured data

This is what sets Semantic Logger apart. Instead of building a sentence by hand, pass the data as a
Hash "payload" after the message:

~~~ruby
# Traditional logging bakes the data into a string:
logger.info("Queried users in #{duration}ms, result #{result}")

# Semantic Logger keeps the message and the data separate:
logger.info("Queried users", duration: duration, result: result, table: "users")
~~~

The message stays readable for a human, and the payload stays machine readable: a JSON, MongoDB, or
Elasticsearch appender indexes `duration`, `result`, and `table` as real fields, so you can search
and build dashboards on them without parsing log text. The fields that make up an entry are listed in
[Log Event](log.html).

## Step 4: Log an exception

Pass a Ruby exception as the second argument. Its class, message, and backtrace are all captured:

~~~ruby
begin
  # ... code that may raise
rescue => exception
  logger.error("Outbound call failed", exception)
end
~~~

To log a payload and an exception together, pass both:

~~~ruby
logger.error("Outbound call failed", {result: :failed}, exception)
~~~

## Step 5: Skip expensive messages with a block

When building the message is itself expensive, pass a block instead of a string. The block runs only
when the level is active, so it costs nothing when that level is turned off (for example in
production):

~~~ruby
logger.debug { "Processed #{records.sum(&:size)} bytes across #{records.size} records" }
~~~

### The full call signature

Putting the pieces together, every level method accepts:

~~~ruby
logger.info(message, payload_or_exception = nil, exception = nil, &block)
~~~

- `message`: the text message. Optional only when a block is supplied.
- `payload_or_exception`: an optional Hash payload, or a Ruby exception.
- `exception`: an optional exception, used when you are also passing a payload.
- `&block`: evaluated only when the level is active; its return value becomes the message.

The same call can also be written as a single Hash, which is handy when assembling fields
programmatically:

~~~ruby
logger.debug(message: "Calling Supplier", payload: {request: "update", user: "Jack"})

# Log a complete exception
logger.error(message: "Calling Supplier", exception: exception)

# Attach a duration of 100ms
logger.error(message: "Calling Supplier", duration: 100)

# Attach a metric (see Step 6)
logger.error(message: "Calling Supplier", metric: "Supplier/inquiry", metric_amount: 21)
~~~

## Step 6: Measure how long something takes

It is good practice to "measure everything" in production, so that when things slow down it is
obvious where the time is going. Wrap the code in a `measure_*` call:

~~~ruby
logger.measure_info("Called external interface") do
  # Code to call the external service ...
end
~~~

The entry is written once the block completes, and includes the duration:

~~~
2012-08-30 15:37:29.474 I [48308:script/rails] (5.2ms) Rails -- Called external interface
~~~

If the block raises, the exception is logged at the same level along with the duration, then re-raised
unchanged. There is a measure method for every level:

~~~ruby
logger.measure_trace / measure_debug / measure_info / measure_warn / measure_error / measure_fatal
~~~

Or supply the level dynamically as the first argument:

~~~ruby
logger.measure(:info, "Request received") do
  # ...
end
~~~

### Only log when it is slow (elastic logging)

Pass `min_duration` (in milliseconds) to log only when the block runs longer than the threshold.
This surfaces slow calls without the noise of the fast ones:

~~~ruby
logger.measure_warn("Called memcache", min_duration: 3) do
  # Usually fast; only logged when it takes longer than 3 ms
end
~~~

### Record a metric

Attach a `metric` name to feed dashboards. See [Metrics](metrics.html):

~~~ruby
logger.measure_info("Called external interface", metric: "Supplier/inquiry") do
  # ...
end
~~~

### Supply the duration yourself

When you already have a duration, log it without a block. This keeps the duration as structured data
rather than embedding it in the message text:

~~~ruby
duration = Time.now - start_time
logger.measure_info("Called external interface", duration: duration)
~~~

Either a block or `:duration` must be supplied on every measure call.

### All measure options

The second argument to a measure call is a Hash of options:

- `:min_duration` [Float]: only log if the block takes longer than this many milliseconds. Default
  `0.0` (always log).
- `:metric` [String]: notify metric subscribers with this metric name.
- `:payload` [Hash]: an optional payload to log with the entry.
- `:exception` [Exception]: an exception to log along with the duration.
- `:duration` [Float]: the duration in ms, used when no block is supplied (then it is mandatory; with
  a block it is ignored).
- `:log_exception` [Symbol]: how to report an exception raised in the block. `:full` logs the class,
  message, and backtrace; `:partial` logs the class and message only; `:off` does not log it.
  Default `:partial`.
- `:on_exception_level` [Symbol]: if an exception is raised, raise the log level to this level.
- `:silence` [Symbol]: the level to silence other log messages to within the block (current thread
  only).

Putting several together:

~~~ruby
logger.measure_info("Called external interface",
                    log_exception: :full,
                    min_duration:  100,
                    metric:        "Custom/Supplier/process") do
  # Code to call the external service ...
end
~~~

## Step 7: Tag related entries

In a concurrent application it is invaluable to find every entry that belongs to one request or job.
`tagged` adds tags to every entry logged inside its block:

~~~ruby
tracking_number = "15354128"

SemanticLogger.tagged(tracking_number) do
  logger.debug("Hello World") # this entry carries the tracking_number tag
end
~~~

Prefer named tags. They are clearer as a system grows, and easier to filter and alert on in a
centralized logging system:

~~~ruby
SemanticLogger.tagged(user: "Jack", zip_code: 12345) do
  logger.debug("Hello World") # carries user and zip_code
end
~~~

Tags are scoped to the current thread, so a new thread started inside the block does not inherit them.
[Parallel Minion](https://github.com/reidmorrison/parallel_minion) creates threads that copy the tags
across automatically.

### Bind tags to one logger (child loggers)

The block form above scopes tags to the thread. Sometimes it is more convenient to bind tags to a
single logger instance, for example when the logger belongs to an object with its own identity (an
ActiveRecord model or a background job).

Calling `tagged` (or its alias `with_tags`) **without a block** returns a new "child" logger that
permanently carries the supplied tags. Every entry from that child, and only that child, includes
them, even across threads:

~~~ruby
class Cart
  include SemanticLogger::Loggable

  def initialize(id)
    @id     = id
    # Bind this Cart's identity to its own logger instance.
    @logger = SemanticLogger["Cart"].tagged(cart_id: id)
  end

  attr_reader :logger

  def add_item(item_id)
    # Automatically tagged with cart_id, without wrapping every method in a block.
    logger.info("Added item", item_id: item_id)
  end
end
~~~

Positional and named tags can be mixed:

~~~ruby
logger = SemanticLogger["Payments"].tagged("billing", region: "eu")
logger.info("Charged card") # tagged with ["billing"] and {region: "eu"}
~~~

Notes:

- The original logger is never modified; `tagged` returns a copy. Child loggers can be nested, each
  level adding to the tags inherited from its parent.
- Instance tags combine with any thread tags from a surrounding `tagged` block: positional thread tags
  come first, then the logger's instance tags. For named tags, the logger's own tags win on a key
  conflict, since they represent its identity.
- Child loggers are ordinary instances, registered nowhere, so they are garbage collected along with
  the object that owns them.

## Going further

The features above cover everyday logging. The rest of this guide covers less common needs.

### Name your threads

Semantic Logger includes the thread name (or id) in every entry. On Ruby MRI the name defaults to the
thread's object id:

~~~
2013-11-07 16:25:14.279 I [35841:70184354571980] (0.0ms) ExternalSupplier -- Calling external interface
~~~

Give a thread a readable name so it stands out in the logs:

~~~ruby
Thread.current.name = "User calculation thread 32"
~~~

~~~
2013-11-07 16:26:02.744 I [35841:User calculation thread 32] (0.0ms) ExternalSupplier -- Calling external interface
~~~

Keep the name unique, otherwise concurrent threads are hard to tell apart. Including the object id is
one way to guarantee that:

~~~ruby
Thread.current.name = "Worker Thread:#{Thread.current.object_id}"
~~~

On JRuby this also sets the underlying JVM thread name, which is useful when monitoring the JVM over
JMX with tools such as jconsole.

### Change one class's level at runtime

Because each class has its own logger, you can change one class's level on the fly, for example to
temporarily turn on `:trace` while diagnosing an issue, without touching the rest of the application:

~~~ruby
# Raise the detail for this one class
ExternalSupplier.logger.level = :trace

# ... reproduce the issue; trace entries from ExternalSupplier are now logged ...

# Return it to following the global default level
ExternalSupplier.logger.level = nil
~~~

To change the global default level for every logger that has not been set explicitly, set
`SemanticLogger.default_level`. See [Configuration](config.html#default-log-level), and
[Signals](operations.html#linux-signals) for changing it in a running process without a restart.

### Silence noisy code

`silence` raises the level within a block, on the current thread only, to quiet a noisy section:

~~~ruby
# Within this block, log only :error and above
logger.silence do
  logger.info "not logged"
  logger.warn "not logged"
  logger.error "but errors are logged"
end
~~~

It can also lower the level within the block, to get more detail from one section:

~~~ruby
logger.silence(:trace) do
  logger.debug "logged, even though the default level is higher"
end
~~~

`silence` has no effect on loggers whose level was set explicitly (those that do not follow the global
default), and does not affect threads spawned inside the block.

### Map a noisy gem's debug logs to trace

Some third party gems log a lot at `:debug`, because they do not have Semantic Logger's `:trace`
level. Wrap such a library's logger in `SemanticLogger::DebugAsTraceLogger` so its `debug` calls are
recorded as `:trace`, keeping them out of your `:debug` output:

~~~ruby
logger = SemanticLogger::DebugAsTraceLogger.new("NoisyLibrary")
logger.debug "Some very low level noisy message" # logged as :trace
~~~

### Capture causal (nested) exceptions

When one exception is rescued and another raised, Ruby records the original as the new exception's
`cause`. Semantic Logger logs the whole chain automatically:

~~~ruby
def oh_no
  File.new("filename", "w").read # raises IOError: not opened for reading
rescue IOError
  raise RuntimeError, "Failed to write to file"
end

begin
  oh_no
rescue StandardError => exception
  logger.error("Failed calling oh_no", exception)
end
~~~

Both exceptions are logged, the second backtrace starting at `Cause:`:

~~~
E [17641:70311685126260 demo.rb:17] Demo -- Failed calling oh_no -- Exception: RuntimeError: Failed to write to file
demo.rb:6:in `rescue in oh_no'
demo.rb:2:in `oh_no'
Cause: IOError: not opened for reading
demo.rb:4:in `read'
demo.rb:4:in `oh_no'
~~~

### Replace the logger in other gems

Rails Semantic Logger already replaces the loggers for many gems. When using Semantic Logger
stand-alone, hand them a Semantic Logger instance yourself:

~~~ruby
Resque.logger          = SemanticLogger[Resque]  if defined?(Resque) && Resque.respond_to?(:logger)
Sidekiq::Logging.logger = SemanticLogger[Sidekiq] if defined?(Sidekiq)
Mongoid.logger         = SemanticLogger[Mongoid] if defined?(Mongoid)
~~~

## Next steps

- [Log Event](log.html): the structure of every entry your filters, formatters, and appenders
  receive.
- [Configuration](config.html): global settings, custom formatters, filtering, and destinations.
- [Operations](operations.html): process forking, performance tuning, signals, and log rotation.
