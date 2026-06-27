---
layout: default
---

## Configuration
{:.no_toc}

**Contents**

* TOC
{:toc}

Semantic Logger is configured once, when your application starts, by setting a few global values
and adding one or more appenders (destinations). This page walks through that configuration from
the simplest, most common settings at the top to formatter and appender customization further down.

Production concerns such as process forking, performance tuning, signals, and log rotation are
covered separately in [Operations](operations.html).

If you are using Rails, most of this is handled for you by the companion gem
[rails_semantic_logger](rails.html); configure it through `config.semantic_logger` and
`config.rails_semantic_logger` instead.

A minimal configuration looks like this:

~~~ruby
require "semantic_logger"

# 1. Choose the lowest level to log.
SemanticLogger.default_level = :info

# 2. Add at least one destination.
SemanticLogger.add_appender(io: $stdout, formatter: :color)

# 3. Get a logger and use it.
logger = SemanticLogger["MyApp"]
logger.info("Ready")
~~~

The sections below explain each piece, and everything you can tune around it.

---

## Global settings

These module level settings apply to the whole process. Set them once, before or just after adding
your appenders.

### Default log level

Semantic Logger logs `:info` and above by default. The levels, from most detail to least, are:

    :trace, :debug, :info, :warn, :error, :fatal

Setting the level to `:debug` includes `:info`, `:warn`, `:error`, and `:fatal`, but not `:trace`.
To log everything, set the global default to `:trace`:

~~~ruby
SemanticLogger.default_level = :trace
~~~

Every logger and appender uses this global default unless it has been given its own level. Once a
logger or appender has an explicit level, changing `SemanticLogger.default_level` no longer affects
it. The global default can also be changed at runtime (see [Signals](operations.html#linux-signals)
for changing it in a running process without a restart):

~~~ruby
SemanticLogger.default_level = :debug
~~~

### Application, environment, and host name

Semantic Logger can include the application name, environment, and host name in every log entry.
Not every appender uses these fields, but structured appenders (JSON, Elasticsearch, Splunk, and so
on) and centralized logging systems rely on them to tell apart logs coming from different
applications and servers:

~~~ruby
SemanticLogger.application = "my_app"
SemanticLogger.environment = "production"
SemanticLogger.host        = "web-server-1"
~~~

When not set explicitly, these default to:

- `application`: the `SEMANTIC_LOGGER_APP` environment variable, otherwise `"Semantic Logger"`.
- `environment`: the first of `SEMANTIC_LOGGER_ENV`, `RAILS_ENV`, or `RACK_ENV` that is set.
- `host`: the machine's host name.

Each value can also be overridden for a single appender by passing `application:`, `environment:`,
or `host:` to `add_appender` (see [Per-appender settings](#per-appender-settings)).

### Capturing backtraces

Semantic Logger can capture the file name and line number where each log entry was created, include
it in the output, and forward it to error services such as Bugsnag.

Capturing a backtrace is expensive, so it is controlled by its own level, which defaults to
`:error`. Only entries at this level or higher capture a backtrace:

~~~ruby
# Capture backtraces for :error and :fatal entries (the default)
SemanticLogger.backtrace_level = :error
~~~

To capture a backtrace for every entry, set it to `:trace`. To turn backtrace capture off entirely,
set it to `nil`. It is strongly recommended to leave this at `:error` or higher in production.

### Caching loggers

By default `SemanticLogger[...]` returns a brand new logger instance on every call. Enable logger
caching to have a single shared logger returned per class:

~~~ruby
SemanticLogger.cache_loggers = true

SemanticLogger[MyClass].equal?(SemanticLogger[MyClass]) # => true
~~~

This makes it possible to obtain a logger once and later change its level (or filter) so that every
holder of that logger sees the change:

~~~ruby
SemanticLogger[MyClass].level = :debug
~~~

Notes:

- Caching is opt-in and disabled by default.
- Only Classes and Modules are cached. A String always returns a new instance, since string call
  sites commonly want an independent logger (for example to set a different level per call site).
- Anonymous classes (those without a name) are never cached.
- With caching enabled, `SemanticLogger[MyClass]` and the `SemanticLogger::Loggable` mixin's
  `MyClass.logger` return the same instance.
- Setting `SemanticLogger.cache_loggers = false` clears the cache. It can also be cleared explicitly
  with `SemanticLogger.clear_logger_cache`, for example after redefining a class.

---

## Per-appender settings

Each destination is added with `SemanticLogger.add_appender`. The full catalogue of destinations,
and the options specific to each, is in [Appenders](appenders.html). In addition to its own
settings, almost every appender accepts these common options:

| Option | Description |
|--------|-------------|
| `level` | Only write entries at this level or higher to this appender. Defaults to `SemanticLogger.default_level`. |
| `formatter` | How to format the output, for example `:default`, `:color`, or `:json`. See [Custom formatters](#custom-formatters). |
| `filter` | A `Regexp` or `Proc` selecting which entries this appender accepts. See [Filtering](#filtering). |
| `application`, `environment`, `host` | Override the global values for this appender only. |

A per-appender `level` lets each destination keep a different subset of the logs. For example, keep
a full trace log and a separate warnings-only log:

~~~ruby
require "semantic_logger"

SemanticLogger.default_level = :info

# Everything at :trace and above:
SemanticLogger.add_appender(file_name: "log/trace.log",    level: :trace)

# Only warnings and above:
SemanticLogger.add_appender(file_name: "log/warnings.log", level: :warn)
~~~

---

## Filtering

A filter decides, for each log entry, whether it should be written. Use a filter to:

* Quiet a noisy library without modifying its code.
* Send only certain messages to a particular destination (for example, a dedicated audit file).
* Strip sensitive data out of a message before it is written.

### A filter is one of three things

1. **A regular expression.** It is matched against the **class name** of the logger (the value you
   passed to `SemanticLogger["..."]`). The entry is kept only if the class name matches.

   ```ruby
   filter: /MyClass/
   ```

2. **A Proc (or lambda).** It receives the whole log event and must return `true` to **keep** the
   entry. Returning anything else (`false`, `nil`, a string, ...) **drops** it.

   ```ruby
   filter: ->(log) { log.message !~ /heartbeat/ }
   ```

3. **A module or object that responds to `.call`.** Same contract as a Proc, but in a named,
   reusable, testable place. Reach for this when the logic grows beyond a one-liner.

   ```ruby
   module ExcludeHealthChecks
     def self.call(log)
       !log.message.to_s.start_with?("GET /health")
     end
   end

   filter: ExcludeHealthChecks
   ```

> **The most common gotcha:** a Proc or `.call` filter must return **exactly `true`** to keep an
> entry. `0`, `"yes"`, or any truthy-but-not-`true` value will silently drop the entry. When in
> doubt, end the filter with an explicit boolean expression.

The log event passed to a Proc or module filter carries every attribute of the message: `name`,
`message`, `level`, `payload`, `tags`, `named_tags`, `duration`, `exception`, and more. The full
list is in [Log Event](log.html).

### Where a filter can be attached

* **On an appender** (a destination). The filter affects only what *that one destination* writes.
  Use this to give one file or service a curated subset of the logs.
* **On a logger instance.** The filter affects *every* appender, but only for entries coming
  *through that one logger*. Use this to quiet a single class or library across all destinations.

### Example: appender filter with a regular expression

Keep a full log in `development.log`, and additionally maintain a `my_class.log` that contains
**only** the messages from `MyClass`:

```ruby
require "semantic_logger"

# Step 1: a catch-all appender that records everything.
SemanticLogger.add_appender(file_name: "development.log")

# Step 2: a second appender that only keeps entries whose logger class name matches /MyClass/.
SemanticLogger.add_appender(file_name: "my_class.log", filter: /MyClass/)

# Step 3: log from two different classes.
SemanticLogger["MyClass"].info "Written to BOTH development.log and my_class.log"
SemanticLogger["OtherClass"].info "Written ONLY to development.log"
```

You can also set the filter after the appender exists:

```ruby
appender        = SemanticLogger.add_appender(file_name: "my_class.log")
appender.filter = /MyClass/
```

### Example: appender filter with a Proc

A `summary.log` that contains everything **except** the (very chatty) messages from `MyClass`:

```ruby
SemanticLogger.add_appender(
  file_name: "summary.log",
  # Keep the entry (return true) unless it came from MyClass.
  filter: ->(log) { log.name != "MyClass" }
)
```

Because the Proc receives the whole log event, you can filter on anything:

```ruby
# Drop entries below a duration threshold (only keep slow measure calls).
filter: ->(log) { log.duration.to_f >= 100 }

# Drop a specific noisy message regardless of which class logged it.
filter: ->(log) { log.message !~ /\Aheartbeat/ }
```

### Example: rewriting a message inside a filter

A filter can also **modify** the log event before it is written, as long as it still returns `true`
so the (now edited) entry is kept. This is handy for redacting sensitive data. Resque, for example,
logs the entire job payload, which may contain private information:

```ruby
Resque.logger.filter = ->(log) do
  if log.name == "Resque" && (match = log.message.to_s.match(/\A(got|done): /))
    log.message = match[1] # replace the full payload with just the action
  end
  true # always return true so the (edited) message is still logged
end
```

### Example: logger filter to quiet a library

When a library lets you replace its logger, attach a filter to a logger instance to suppress its
noise everywhere it is logged, without touching any appender:

```ruby
logger        = SemanticLogger[Resque]
logger.filter = ->(log) { log.message !~ /\A\*\*\* Checking/ }
Resque.logger = logger
```

---

## Custom formatters

The formatter turns each log event into the text or JSON that an appender writes. Pass a
`formatter:` when adding an appender. The simplest options are the built-in formatters selected by
name (`:default`, `:color`, `:json`, `:logfmt`, and others; see [Appenders](appenders.html)). For
anything beyond those, you have three choices, in increasing order of effort: a pattern string, a
Proc, or a formatter class.

### Pattern formatter

For simple layout changes there is no need to write any code. The built-in `:pattern` formatter
builds each log line from a pattern string. Placeholders use the form `%{directive}`; to emit a
literal `%{...}`, escape it as `%%{...}`.

~~~ruby
# A message-only format on stdout, for end users:
SemanticLogger.add_appender(
  io:        $stdout,
  formatter: {pattern: {pattern: "%{message}"}}
)

# A timestamped format to a file:
SemanticLogger.add_appender(
  file_name: "application.log",
  formatter: {pattern: {pattern: "%{time} %{level} %{name} -- %{message}"}}
)
~~~

The pattern is parsed once when the appender is created, so formatting every entry is fast. An
unknown directive (or an argument supplied to a directive that does not take one) raises an error
immediately, when the appender is configured.

Available directives:

| Directive              | Description                                              |
|------------------------|----------------------------------------------------------|
| `%{time}`              | Formatted timestamp. A strftime format may be supplied, e.g. `%{time:%Y-%m-%dT%H:%M:%S.%6N}`. |
| `%{level}`             | Full level name, e.g. `debug`.                           |
| `%{level_short}`       | Single character level, e.g. `D`.                        |
| `%{name}`              | Logger / class name.                                     |
| `%{message}`           | Log message.                                             |
| `%{payload}`           | Payload rendered as a string.                            |
| `%{exception_class}`   | Class of the logged exception, e.g. `RuntimeError`.      |
| `%{exception_message}` | Message of the logged exception.                         |
| `%{backtrace}`         | Backtrace of the logged exception.                       |
| `%{duration}`          | Human readable duration, e.g. `1.2ms`.                   |
| `%{duration_ms}`       | Duration in milliseconds (numeric).                      |
| `%{thread_name}`       | Name of the thread that logged the message.              |
| `%{pid}`               | Process id.                                              |
| `%{file_name}`         | Ruby file name that logged the message, e.g. `app.rb`.   |
| `%{line}`              | Line number within the Ruby file, e.g. `42`.             |
| `%{tags}`              | Tags, comma separated.                                   |
| `%{named_tags}`        | All named tags. One tag with `%{named_tags:request_id}`. |
| `%{host}`              | Host name.                                               |
| `%{application}`       | Application name.                                        |
| `%{environment}`       | Environment name.                                        |

When the pattern is omitted it defaults to a layout similar to the default text formatter:
`%{time} %{level} [%{pid}:%{thread_name}] %{name} -- %{message}`.

#### Example: a custom timestamp format

The `%{time}` directive accepts a [strftime](https://ruby-doc.org/core/Time.html#method-i-strftime)
format string, applied directly to the log time:

~~~ruby
SemanticLogger.add_appender(
  io:        $stdout,
  formatter: {pattern: {pattern: "%{time:%Y-%m-%dT%H:%M:%S.%6N%z} %{level} -- %{message}"}}
)
# => 2017-04-05T01:05:52.868286+0000 info -- Hello World
~~~

#### Example: include a request id from the named tags

Named tags (set with `SemanticLogger.tagged(request_id: "...")`) can be pulled out individually with
`%{named_tags:key}`:

~~~ruby
SemanticLogger.add_appender(
  io:        $stdout,
  formatter: {pattern: {pattern: "%{time} %{level} [%{named_tags:request_id}] %{name} -- %{message}"}}
)
~~~

### Formatter as a Proc

For full control with minimal ceremony, supply a block. It is called with two arguments, the log
event and the appender; a block may accept just the log event and ignore the appender. For the
structure of the log event, see [Log Event](log.html).

~~~ruby
formatter = proc do |log|
  # This formatter just returns the log event as a string
  log.inspect
end
SemanticLogger.add_appender(io: $stdout, formatter: formatter)
~~~

### Formatter as a class

When the formatting logic is substantial or reused, subclass one of the built-in formatters and
override just the methods you want to change.

Override the default text formatter to upper-case the level name:

~~~ruby
class MyFormatter < SemanticLogger::Formatters::Default
  # Return the complete log level name in uppercase
  def level
    log.level.upcase
  end
end

SemanticLogger.add_appender(file_name: "development.log", formatter: MyFormatter.new)
~~~

The colorized formatter can be customized the same way, keeping its color codes:

~~~ruby
class MyFormatter < SemanticLogger::Formatters::Color
  def level
    "#{color}#{log.level.upcase}#{color_map.clear}"
  end
end

SemanticLogger.add_appender(file_name: "development.log", formatter: MyFormatter.new)
~~~

A common request is to leave out the process id, for example when running a single process per
container (where the pid is always 1):

~~~ruby
class NoPidFormatter < SemanticLogger::Formatters::Default
  # Leave out the pid
  def pid
  end
end

SemanticLogger.add_appender(file_name: "development.log", formatter: NoPidFormatter.new)
~~~

See
[SemanticLogger::Formatters::Default](https://github.com/reidmorrison/semantic_logger/blob/main/lib/semantic_logger/formatters/default.rb)
and
[SemanticLogger::Formatters::Color](https://github.com/reidmorrison/semantic_logger/blob/main/lib/semantic_logger/formatters/color.rb)
for all the methods that can be overridden.

To replace the formatter on an appender that is already installed, for example in a Rails app:

~~~ruby
# Find the file appender and replace its formatter:
appender = SemanticLogger.appenders.find { |a| a.is_a?(SemanticLogger::Appender::File) }
appender.formatter = MyFormatter.new
~~~

### Escaping control characters

By design, the human readable text formatters (`:default` and `:color`) write log messages exactly
as supplied, including newlines and ANSI color codes. This is intentional and useful: multi-line
messages and colorized output make local logs easier to read.

When log messages can contain untrusted, attacker-controlled data (for example a user name, request
parameter, or `User-Agent` header), those same characters can be abused. A newline can forge an
additional, fake log entry ("log forging"), and an ANSI escape sequence can spoof or hide terminal
output when the log is viewed in a terminal.

Structured formatters such as `:json` are not affected, because JSON encoding always escapes control
characters. They are the recommended choice when forwarding logs that may contain untrusted data to
a centralized logging system.

For the text formatters, enable the `escape_control_chars` option to replace control characters in
untrusted log data (the message, tags, named tags, and exception message) with a printable, escaped
form. For example a newline is written as `\n` and the ANSI escape as `\e`. The option is **disabled
by default** to preserve the existing human readable output:

```ruby
# Text appender that escapes control characters in untrusted data:
SemanticLogger.add_appender(file_name: "production.log", formatter: {default: {escape_control_chars: true}})

# Colorized appender, still escaping control characters in the logged data
# (the formatter's own color codes are preserved):
SemanticLogger.add_appender(io: $stdout, formatter: {color: {escape_control_chars: true}})
```

The option only escapes the control characters in the logged data; it does not touch the formatter's
own decoration, so the `:color` formatter keeps emitting its color codes. Multi-line exception
backtraces are also preserved, since they are generated by Semantic Logger rather than supplied as
log data. The pattern formatter supports the same option (`{pattern: {pattern: "...",
escape_control_chars: true}}`), and the syslog, TCP, and UDP appenders enable it where appropriate;
see [Appenders](appenders.html).

---

## Custom appenders

To write your own log appender it should meet the following requirements:

* Inherit from `SemanticLogger::Subscriber`.
* In the initializer, connect to the resource being logged to.
* Implement `#log(log)`, which writes to the relevant resource.
* Implement `#flush` if the resource can be flushed.
* Write a test for the new appender.

The `#log` method receives the log event as its parameter. For its structure, see
[Log Event](log.html).

Basic outline for an appender:

~~~ruby
require "semantic_logger"

class SimpleAppender < SemanticLogger::Subscriber
  attr_reader :host

  # Add additional arguments to the initializer while supporting all existing ones.
  def initialize(host: host, **args, &block)
    @host = host
    super(**args, &block)
  end

  # Display the log struct and the text formatted output
  def log(log)
    # Display the raw log structure
    p log

    # Display the formatted output
    puts formatter.call(log, self)
  end

  # Optional
  def flush
    puts "Flush :)"
  end

  # Optional
  def close
    puts "Closing :)"
  end
end
~~~

Register the appender by passing an instance to `add_appender`:

~~~ruby
SemanticLogger.add_appender(appender: SimpleAppender.new)
~~~

Look at the
[existing appenders](https://github.com/reidmorrison/semantic_logger/tree/main/lib/semantic_logger/appender)
for good examples. To have a custom appender included in the standard list, submit it with complete
working tests; see the
[Graylog Appender Test](https://github.com/reidmorrison/semantic_logger/blob/main/test/appender/graylog_test.rb)
for an example.

---

## Managing appenders and lifecycle

### Adding and removing appenders

`SemanticLogger.add_appender` returns the appender it created, which can be used to remove that
appender later:

~~~ruby
appender = SemanticLogger.add_appender(file_name: "development.log")

# ... later
SemanticLogger.remove_appender(appender)
~~~

Other appender management methods:

~~~ruby
# The list of currently active appenders
SemanticLogger.appenders

# Remove and close every appender
SemanticLogger.clear_appenders!

# Flush all appenders, then close them ( called automatically at process exit )
SemanticLogger.close
~~~

### Flushing

Semantic Logger automatically flushes all appenders (log files, etc.) when a process exits. The
`flush` method is not defined on individual logger instances, since there may be many of them. To
perform a global flush of all appenders and wait for any queued messages to be written:

~~~ruby
SemanticLogger.flush
~~~

### Capturing context with `on_log`

Register a block to be called for every log entry, just before it is placed on the queue. The block
runs inline on the thread that created the entry, so it can capture request-scoped or thread-local
context that would otherwise be lost once the entry is handed off to the background thread:

~~~ruby
SemanticLogger.on_log do |log|
  log.set_context(:request_id, Thread.current[:request_id])
end
~~~

Because these callbacks run on the application's own thread, keep them fast. The captured context is
available to appenders and formatters as `log.context`.
