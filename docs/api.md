---
layout: default
title: Programming Guide
description: >-
  How to log with Semantic Logger: getting a logger, log levels, structured
  payloads, exceptions, the block form, measuring durations, and tagging
  related entries.
---


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

A module can include `SemanticLogger::Loggable` too. The module gets a `logger` of its own, and its
instance methods get a `logger` in any class that includes the module, whether or not that class
includes `SemanticLogger::Loggable`:

~~~ruby
module Pricing
  include SemanticLogger::Loggable

  def price(amount)
    logger.info("Pricing", amount: amount)
  end
end

class Order
  include Pricing
end

Order.new.price(10)
~~~

The entry is identified as coming from `Order`, the class that called `price`. When that class has a
class level `logger`, such as one from `SemanticLogger::Loggable`, the module's methods use it instead.
When the class itself defines a `logger` instance method, they use that.

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

# Attach a backtrace of your own, an Array of Strings, instead of the logger's call stack
logger.warn(message: "Open redirect detected", backtrace: redirect_stack)

# Say where the entry was logged, or that it has no such place (see call_site_level)
logger.debug(message: "Order Load", duration: 0.4, call_site: query_location)
logger.info(message: "Started GET /orders", call_site: false)
~~~

In both forms, a key such as `duration` or `exception` is only used as an argument when its value is
valid for it; otherwise it is logged as part of the payload. Any other keys supplied alongside
`payload:` are merged into it, without overwriting its own values. When the Hash holds untrusted
data, see [Logging untrusted hashes](security.html#logging-untrusted-hashes).

A block can return the same Hash, but it never replaces an argument the entry already has. That
includes the backtrace that an entry captures when its level is at or above
`SemanticLogger.backtrace_level`, so to attach a backtrace of your own, pass `backtrace:` with the
call rather than returning it from the block.

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

Attach a `metric` name to feed dashboards. Once a metric appender is added, the duration is
recorded as a metric at every level, and whether or not `min_duration` is met, while the log entry
still follows the log level. See [Metrics](metrics.html):

~~~ruby
logger.measure_info("Called external interface", metric: "Supplier/inquiry") do
  # ...
end
~~~

To time code for a metric without logging it, use `logger.time` instead:

~~~ruby
logger.time("supplier.inquiry") { supplier.inquiry }
~~~

Add `dimensions` to break the metric down, such as by supplier. See
[Dimensions](metrics.html#dimensions):

~~~ruby
logger.measure_info("Called external interface",
                    metric:     "Supplier/inquiry",
                    dimensions: {supplier: "acme"}) do
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
- `:metric` [String]: record the duration as a metric with this name, once a metric appender is
  added, at every level. It must be in the options before the call to be timed below the level.
- `:dimensions` [Hash]: key/value labels that break the metric down, such as `{supplier: "acme"}`.
- `:payload` [Hash]: an optional payload to log with the entry.
- `:exception` [Exception]: an exception to log along with the duration.
- `:duration` [Float]: the duration in ms, used when no block is supplied (then it is mandatory; with
  a block it is ignored).
- `:log_exception` [Symbol]: how to report an exception raised in the block. `:full` logs the class,
  message, and backtrace of the exception and of each exception that caused it; `:partial` adds their
  classes and messages to the log message, without backtraces; `:none` does not log it. Default
  `:partial`. With `:partial`, a cause's message is left out when it is empty, is its class name, or
  is already in the log message, as when the exception that wraps it copied it into its own:

  ```
  Rendering -- Exception: ActionDispatch::Http::MimeNegotiation::InvalidType: "foo/bar" is not a valid MIME type -- Cause: Mime::Type::InvalidMimeType
  ```
- `:on_exception_level` [Symbol]: if an exception is raised, raise the log level to this level.
- `:silence` [Symbol]: the level to silence other log messages to within the block (current fiber
  only).
- `:call_site` [Thread::Backtrace::Location|SemanticLogger::CallSite|false]: where the entry was
  logged, or `false` for none. See
  [Recording where each entry was logged](config.html#recording-where-each-entry-was-logged).

An option with a value that is not valid for it, such as a non-numeric `:min_duration` or an unknown
level, is ignored and its default is used. Other keys in the Hash are not logged; pass the data to
log as `:payload`.

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

Tags belong to the current fiber: each thread has its own, and so does each fiber of a fiber
scheduler such as [Async](https://github.com/socketry/async), which runs every request of a
[Falcon](https://github.com/socketry/falcon) server in its own fiber. So concurrent requests never
see each other's tags, and a thread, fiber, or Async task started inside the block does not have
them either. Hand them over explicitly, as shown next.

### Hand tags to another thread or fiber

`SemanticLogger.context` returns a frozen snapshot of the current tags, named tags, and
[silence](#silence-noisy-code) level. `SemanticLogger.with_context` applies it in another thread or
fiber for the duration of a block:

~~~ruby
SemanticLogger.tagged(request_id: request.uuid) do
  context = SemanticLogger.context

  Thread.new do
    SemanticLogger.with_context(context) do
      logger.info("Generating report") # carries request_id
    end
  end
end
~~~

The same works for an Async task or a thread pool:

~~~ruby
context = SemanticLogger.context
barrier = Async::Barrier.new
urls.each do |url|
  barrier.async do
    SemanticLogger.with_context(context) { fetch(url) }
  end
end
barrier.wait

context = SemanticLogger.context
pool.post do
  SemanticLogger.with_context(context) { process(item) }
end
~~~

Within the block, the thread or fiber has exactly the tags, named tags, and silence level of the
snapshot, in place of its own, which come back when the block exits. Add more tags inside the block
as usual. The snapshot does not carry levels set with a logger's `with_level`, which, like Ruby's own
`Logger#with_level`, apply only to the fiber that set them.

Tags are not handed over automatically because a long-lived thread, such as a thread pool's worker,
would otherwise keep the tags of whichever request happened to start it, and log them for every
later request it serves.

### Bind tags to one logger (child loggers)

The block form above scopes tags to the fiber. Sometimes it is more convenient to bind tags to a
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

Semantic Logger includes the thread name in every entry. A thread that has no name is identified by
its object id instead:

~~~
2013-11-07 16:25:14.279 I [35841:16] (0.0ms) ExternalSupplier -- Calling external interface
~~~

Give a thread a readable name so it stands out in the logs:

~~~ruby
Thread.current.name = "User calculation thread 32"
~~~

~~~
2013-11-07 16:26:02.744 I [35841:User calculation thread 32] (0.0ms) ExternalSupplier -- Calling external interface
~~~

Keep the name unique, otherwise concurrent threads are hard to tell apart. For example, number the
threads in a pool:

~~~ruby
workers = Array.new(5) do |i|
  Thread.new do
    Thread.current.name = "calc #{i + 1}"
    # ...
  end
end
~~~

This is Ruby's own `Thread#name=`, so the name must be a String, and Ruby raises for one that
contains a NUL byte or is not in an ASCII-compatible encoding. Ruby also gives the name to the
operating system, so it shows up in tools that list threads, such as `top -H`, debuggers, and
profilers. Log entries show the whole name, but Linux keeps only its first 15 bytes, so keep the
name short, or put the part that tells threads apart first. Semantic Logger keeps its own thread
names short for the same reason, naming each after its appender, such as `SL Appenders` and
`SL File`.

On JRuby, naming a thread also names the underlying JVM thread, which shows up when monitoring the
JVM with tools such as jconsole or jstack. JRuby names the main thread `main`, and a thread created
by Java code, such as a servlet container's request thread, is logged with its JVM thread name.

### Log from Ractors (experimental)

On Ruby 4.0 and later, code running in a [Ractor](https://docs.ruby-lang.org/en/4.0/Ractor.html)
logs as usual, and the entries are written by the appenders added in the main Ractor. Like Ruby's
own Ractor API, this is experimental, and may change in a minor release.

~~~ruby
SemanticLogger.add_appender(io: $stdout, formatter: :color)

context = SemanticLogger.tagged(job_id: 42) { SemanticLogger.context }
worker  = Ractor.new(context, name: "worker") do |job_context|
  SemanticLogger.with_context(job_context) do
    logger = SemanticLogger["Importer"]
    logger.info("Importing", rows: 1_000) # carries job_id: 42
  end
end
worker.join
~~~

Each entry is sent to the main Ractor, where a thread hands it to the appenders, so a Ractor never
waits on an appender. The thread name of an entry starts with the Ractor's name, or its number, as in
`worker/12345` or `ractor-3/12345`.

Things to know:

- A new Ractor does not have the tags of the code that created it. Hand them over with
  [`SemanticLogger.context`](#hand-tags-to-another-thread-or-fiber), as shown above.
- Add appenders, and change any setting, such as `SemanticLogger.default_level`, in the main Ractor.
  Doing so in another Ractor raises `Ractor::IsolationError`.
- Each Ractor has its own loggers: a `Loggable` class has a logger of its own in each Ractor, and so
  does a class with `SemanticLogger.cache_loggers` enabled. Setting a level on the main Ractor's logger
  therefore does not change the level of a Ractor's logger; the global default level applies to both.
- `on_log` subscribers run for an entry logged in a Ractor only when they are shareable, such as a
  module with a `call` method, or a block made with `Ractor.shareable_proc`.
- An entry is copied to the main Ractor. A value that Ruby cannot copy, such as a Proc in the payload,
  is written as its `inspect`, and so is such a value held by a logged exception. The extra detail
  that Ruby adds to some exceptions' messages, such as did_you_mean's "Did you mean?" suggestions, is
  not written for an exception logged in a Ractor.
- `SemanticLogger.flush` in a Ractor waits until the main Ractor has written that Ractor's entries.
- The main Ractor accepts entries from other Ractors as fast as they are logged, so logging never
  slows a Ractor down, however busy the appenders are. `max_queue_size` and `non_blocking` then apply
  to the entries as usual, once the receiving thread hands them to the processor. In sync mode, too,
  the receiving thread writes them.
- On Ruby 3.4 and earlier, logging from a Ractor other than the main one raises
  `Ractor::IsolationError`, as it always has.

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

`silence` raises the level within a block, on the current fiber only, to quiet a noisy section:

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
default), and does not affect threads or fibers started inside the block, unless they are handed the
block's [context](#hand-tags-to-another-thread-or-fiber).

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
Resque.logger  = SemanticLogger[Resque]  if defined?(Resque) && Resque.respond_to?(:logger)
Mongoid.logger = SemanticLogger[Mongoid] if defined?(Mongoid)

Sidekiq.configure_server do |config|
  config.logger = SemanticLogger[Sidekiq]
end
~~~

## Next steps

- [Log Event](log.html): the structure of every entry your filters, formatters, and appenders
  receive.
- [Configuration](config.html): global settings, custom formatters, filtering, and destinations.
- [Operations](operations.html): process forking, performance tuning, signals, and log rotation.
