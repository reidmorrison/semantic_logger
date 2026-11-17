---
layout: default
title: Configuration
description: >-
  Configure Semantic Logger once at startup: global settings, per-appender
  levels and formats, filtering, and writing your own formatters and
  appenders.
---


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

The default and `:color` text formatters do not print these values. To see them in text output, use
the `:pattern` formatter with `%{application}`, `%{environment}`, or `%{host}`, or a structured
formatter such as `:json`.

### Capturing backtraces

Semantic Logger can capture the backtrace of the code that created each log entry, include its file
name and line number in the output, and forward it to error services such as Bugsnag. To record only
where each entry was logged, at a fraction of the cost, see
[Recording where each entry was logged](#recording-where-each-entry-was-logged) below.

Capturing a backtrace is expensive, so it is controlled by its own level, which defaults to
`:error`. Only entries at this level or higher capture a backtrace:

~~~ruby
# Capture backtraces for :error and :fatal entries (the default)
SemanticLogger.backtrace_level = :error
~~~

To capture a backtrace for every entry, set it to `:trace`. To turn backtrace capture off entirely,
set it to `nil`. It is strongly recommended to leave this at `:error` or higher in production.

### Recording where each entry was logged

To record the file, line, and method of the code that made each log call, set `call_site_level`.
Entries at this level or higher record their call site. It is off (`nil`) by default:

~~~ruby
# Record where :info and higher entries were logged
SemanticLogger.call_site_level = :info

# Every entry
SemanticLogger.call_site_level = :trace

# Off (the default)
SemanticLogger.call_site_level = nil
~~~

In Rails, set it in `config/application.rb` with `config.semantic_logger.call_site_level = :info`.

The text formatters then show the method after the file name and line number, and the JSON formatter
adds a `method` field:

~~~
2026-11-15 13:58:05.906754 I [8462:main order.rb:42 Order#submit] Order -- Submitted
~~~

~~~json
{"file":"/app/models/order.rb","line":42,"method":"Order#submit","name":"Order","message":"Submitted"}
~~~

Unlike a backtrace, the call site is found by reading only the stack frames up to the code that made
the log call. A backtrace builds a String for every frame of the stack, so its cost grows with the
depth of the stack:

| | `backtrace_level` | `call_site_level` |
|-|-------------------|-------------------|
| Records | The whole stack, as an Array of Strings | The file, line, and method of the log call |
| Time added to a `logger.info` call, 100 frames deep | About 16 µs (Ruby 3.2) to 26 µs (Ruby 4.0) | About 1.5 µs |
| On a deeper stack | Grows with the depth | The same |
| Default | `:error` | `nil` (off) |

(Measured on an Apple M5; a `logger.info` call without either takes about 1.3 µs. Reading the stack
costs much more on JRuby: about 25 µs for the call site, and 180 µs for a backtrace.) The call site is
cheap enough to record for every entry in most applications, but it still about doubles the time a
log call spends on the thread that logs, so measure it when an application logs at a very high rate.

The method is the label Ruby gives the frame in a backtrace:

| Code that logged | Ruby 3.4 and later | Ruby 3.2, 3.3, and JRuby |
|------------------|--------------------|--------------------------|
| Instance method | `Order#submit` | `submit` |
| Class method | `Order.find_open` | `find_open` |
| Block inside a method | `block in Order#submit` | `block in submit` |
| Method defined with `define_method` | `block in <class:Order>` | `block in <class:Order>` |
| Outside any method | `<main>`, `<class:Order>` | `<main>`, `<class:Order>` |

JRuby gives a method defined with `define_method` its name, such as `submit`.

Where each formatter writes the call site:

| Formatter | File and line | Method |
|-----------|---------------|--------|
| `:default`, `:color`, `:one_line`, `:syslog` | `order.rb:42`, after the thread name | After the line number |
| `:pattern` | `%{file_name}`, `%{line}` | `%{method}` |
| `:json`, `:raw`, `:syslog_cee`, `:fluentd` (with `need_process_info: true`), and the appenders that use them | `file`, `line` | `method` |
| `:ecs` | `log.origin.file.name`, `log.origin.file.line` | `log.origin.function` |
| `:new_relic_logs` | `file.name`, `line.number` | `method.name` |
| `:open_telemetry` | `code.file.path`, `code.line.number` | `code.function.name` |

The `:logfmt` and `:loki` formatters write neither. A custom formatter reads the call site from
[`log.call_site`](log.html#attributes).

Which code counts as the call site:

* When the log call, or a `measure_*` call, supplies `call_site:`, that call site. Code that logs on
  behalf of other code, such as a log subscriber, can say which code the entry is about with a
  `Thread::Backtrace::Location` (for example from `Thread.each_caller_location`) or a
  `SemanticLogger::CallSite`, or that it has no such code with `false`, which records no call site
  without reading the stack for one. `nil` means none was supplied, so the call site is found as
  usual. A supplied call site is only recorded when the entry is at or above `call_site_level`, so
  that it never adds a call site to the output of an application that has not turned call sites on:

  ~~~ruby
  # The application code that ran the query, or none when no frame is the application's
  logger.debug(message: "Order Load", duration: 0.4,
               call_site: backtrace_cleaner.first_clean_location || false)
  logger.info(message: "Started GET /orders", call_site: false)
  ~~~

  A String, or any other value that parsed data can hold, is not accepted as a call site, nor is a
  `CallSite` without a String path, an Integer line, and a String or `nil` label: a log call logs it
  as part of the payload, and a `measure_*` call ignores it. An entry
  with `call_site: false` that captures a backtrace (see `backtrace_level`), or logs an exception,
  still has a file name and line number from that backtrace, as the last point below says.
* The first frame outside Semantic Logger, `rails_semantic_logger`, and Ruby's internal files (paths
  that start with `<internal:`). So an entry logged by a `measure_*` call, or by a logging block,
  records the code that called the logger. When the logger is called through `public_send`,
  `Method#call`, or `UnboundMethod#bind_call`, the call site is the code that called that method. (On
  JRuby, `Method#call` inside a block records the right file and line, but the label `block in call`.)
  Code in Ruby's standard library that calls the logger for you, such as a method that `Forwardable`
  delegates, is recorded as the call site: add its path to `call_site_skip_paths` (see below).
* When the log call supplies a `backtrace:`, the first line of that backtrace. For example
  `logger.backtrace` passes the backtrace of the thread it logs, and `rails_semantic_logger` passes
  the application code that ran a SQL query when it captures a backtrace for the entry (see
  `backtrace_level` above). A backtrace returned by a logging block does not change the call site.
* Entries that `rails_semantic_logger` logs for Rails' own events, such as `Processing`,
  `Completed`, `Rendered`, and SQL entries without a backtrace, are logged from Active Support's
  notifications, so their call site is an Active Support frame rather than the application's code.
* With a call site, an entry's file name and line number are the call site's, also for an entry that
  logs an exception. Without one, they still come from a captured backtrace, or else the first line
  of the exception's backtrace.

Code that logs on behalf of its caller, such as an application's own logging helper, would always be
recorded as the call site. Skip its frames with `call_site_skip_paths`, so that entries record the
code that called it. Each entry matches any file whose path includes it:

~~~ruby
# AuditLog.record(...) logs for its callers
SemanticLogger.call_site_skip_paths = ["app/lib/audit_log.rb"]

# Every file of a gem that wraps the logger
SemanticLogger.call_site_skip_paths = ["app/lib/audit_log.rb", "/my_logging_gem/"]
~~~

### Cleaning backtraces

Most of an exception's backtrace is usually gems and Ruby itself, with the application's own frames
somewhere in the middle. A backtrace cleaner leaves out or shortens lines before they are logged.
Set the application's cleaner once:

~~~ruby
SemanticLogger.backtrace_cleaner = Rails.backtrace_cleaner
~~~

A cleaner is any object that responds to `#clean`, as `ActiveSupport::BacktraceCleaner` does, or to
`#call`, such as a Proc. It is given each backtrace as an Array of Strings, and returns the lines to
log:

~~~ruby
app_root = "#{Dir.pwd}/"
SemanticLogger.backtrace_cleaner = lambda do |lines|
  lines.select { |line| line.start_with?(app_root) }.map { |line| line.delete_prefix(app_root) }
end
~~~

Only the text and JSON output changes: the `:default`, `:color`, `:pattern`, `:one_line`
(which does not write backtraces), `:syslog`, `:json`, and `:fluentd` formatters clean the backtrace
of the logged exception and of each exception that caused it. So do the appenders that use `:json`
unless given another formatter: `:http`, `:elasticsearch_http`, `:tcp`, `:udp`, `:kafka`,
`:rabbitmq`, and `:cloudwatch_logs`. To send full backtraces to a log service through one of them,
give it `formatter: {json: {backtrace_cleaner: false}}`.

The exception itself is never changed, so appenders that send the exception to an error service,
such as Sentry, Bugsnag, or Honeybadger, still send its full backtrace. The other formatters,
including `:raw` and the formatters written for a particular service, such as `:ecs`, `:loki`,
`:new_relic_logs`, and `:open_telemetry`, write the full backtrace. So do the `:elasticsearch`,
`:opensearch`, `:mongodb`, `:graylog`, `:splunk_http`, and `:honeybadger_insights` appenders, which
build their entries with formatters of their own: giving one of them a `formatter` replaces how it
builds its entries.

The `backtrace_cleaner` option of an appender's formatter chooses for that appender:

| Value | Cleans backtraces with |
|-------|------------------------|
| `true` | The application's cleaner, `SemanticLogger.backtrace_cleaner`, when one is set. The default for the formatters listed above. |
| `false` | Nothing: the full backtrace is written. The default for every other formatter. |
| A cleaner | That cleaner, in place of the application's. |

~~~ruby
# Keep full backtraces in the JSON file:
SemanticLogger.add_appender(file_name: "production.json", formatter: {json: {backtrace_cleaner: false}})

# Clean the backtraces in logfmt output too:
SemanticLogger.add_appender(io: $stdout, formatter: {logfmt: {backtrace_cleaner: true}})

# Use a cleaner of its own for one appender:
SemanticLogger.add_appender(io: $stdout, formatter: {color: {backtrace_cleaner: MyCleaner.new}})
~~~

Notes:

* When the cleaner leaves out every line, for example for an exception raised entirely inside gems,
  the full backtrace is logged, so the only clue to where it came from is never lost. The full
  backtrace is also logged when the cleaner does not return an Array, or raises an error, which is
  reported to the internal logger.
* The cleaner is called on the appenders' threads, not the thread that logged the entry, so it must be
  thread safe. Its result is kept with the entry, so it is normally called once for each exception,
  however many appenders write it. Appenders that write the same entry at the same moment can each
  call it.
* The application's cleaner is looked up as each entry is written, so it can be set before or after
  the appenders are added.
* The file name and line number of an entry are not cleaned. They are where the entry was logged when
  it has a call site (see `call_site_level` above) or captured a backtrace (see `backtrace_level`
  above), and otherwise the first line of the exception's backtrace.

### Redacting sensitive keys

Name the keys whose values must never be logged, such as passwords and access tokens, and their
values are replaced with `[FILTERED]` in the payload, named tags, context, and metric dimensions of
every log entry, at any depth, before any appender writes it:

~~~ruby
SemanticLogger.sensitive_keys = %i[passw secret token _key authorization cookie]
~~~

Symbols and Strings match any key whose name contains them, ignoring case, as in Rails'
`config.filter_parameters`, and an `ActiveSupport::ParameterFilter`, a Regexp, or a Proc can be given
instead. rails_semantic_logger sets it from `config.filter_parameters`. See
[Redacting sensitive data](security.html#redacting-sensitive-data) for what is matched and redacted,
and what is not.

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
and the options specific to each, is in [Appenders](appenders.html). Each call adds one destination,
given as one of `file_name:`, `io:`, `logger:`, `appender:`, or `metric:`; to write to several, call
it once for each. Given more than one of them, `add_appender` adds only the first, in that order, and
reports a [deprecation warning](upgrading.html#seeing-deprecation-warnings) that names the others,
which it ignores; v6 raises an `ArgumentError`. A destination given as `nil` is not one, so that
optional settings can be passed on, such as `file_name: options[:log_file], io: $stdout`.

In addition to its own settings, almost every appender accepts these common options:

| Option | Description |
|--------|-------------|
| `level` | Only write entries at this level or higher to this appender. Defaults to `SemanticLogger.default_level`. |
| `formatter` | How to format the output, for example `:default`, `:color`, or `:json`. A [block given to `add_appender`](#formatter-as-a-block-or-proc) takes its place. See [Custom formatters](#custom-formatters). |
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
so the (now edited) entry is kept. This is handy for removing sensitive data from a message in a
logger's filter, as below, or in `on_log`. To redact the values of sensitive keys in every entry, use
[`SemanticLogger.sensitive_keys`](#redacting-sensitive-keys) instead. Do not redact in an appender's
filter: every appender writes the same log event, so the appenders added before it have already
written the data. Resque, for example, logs the entire job payload,
which may contain private information:

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
block or Proc, or a formatter class.

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
| `%{exception_details}` | Detail Ruby adds to the exception's message, such as did_you_mean suggestions. See [Exception details](#exception-details). |
| `%{backtrace}`         | Backtrace of the logged exception.                       |
| `%{duration}`          | Human readable duration, e.g. `1.2ms`.                   |
| `%{duration_ms}`       | Duration in milliseconds (numeric).                      |
| `%{thread_name}`       | Name of the thread that logged the message.              |
| `%{pid}`               | Process id.                                              |
| `%{file_name}`         | Ruby file name that logged the message, e.g. `app.rb`.   |
| `%{line}`              | Line number within the Ruby file, e.g. `42`.             |
| `%{method}`            | Method that logged the message, e.g. `Order#submit`, when the entry has a call site. See [Recording where each entry was logged](#recording-where-each-entry-was-logged). |
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

### Formatter as a block or Proc

For full control with minimal ceremony, give `add_appender` a block. It formats every entry written
to that appender. It is called with two arguments, the log event and the appender. A block, or a
Proc made with `proc`, may take just the log event; a lambda or method, passed with `&` or as
`formatter:`, must accept both arguments. For the structure of the log event, see
[Log Event](log.html). The appender holds the `host`, `application`, and `environment` to write
with the entry.

~~~ruby
SemanticLogger.application = "MyApp"

SemanticLogger.add_appender(io: $stdout) do |log, appender|
  "#{log.level.upcase} #{appender.application} #{log.name} -- #{log.message}"
end
# => INFO MyApp Order -- Order submitted
~~~

The block returns what the appender writes. For `io:`, `file_name:`, and `logger:`, return the entry
as a String: `io:` and `file_name:` write it followed by a newline, and `logger:` passes it to the
wrapped logger.

A block works the same way for an appender or metric subscriber named by a Symbol. It takes the
place of the formatter the appender uses by default, so it returns what that formatter returns: a
String for the text and JSON destinations, such as `:tcp`, `:udp`, `:http`, and `:syslog` with its
default local url, and a Hash for those that store a document, such as `:elasticsearch` and
`:mongodb`. For `:loki`, and for `:syslog` with a `tcp://` or `udp://` url, the default formatter
builds the whole request body or syslog packet, so a block would have to build it too: use a
formatter class instead, such as a subclass of `SemanticLogger::Formatters::Loki` or
`SemanticLogger::Formatters::Syslog` (see [Formatter as a class](#formatter-as-a-class)). A metric
subscriber formats a metric: `metric: :new_relic` expects the metric name, `metric: :signalfx` the
JSON body it posts, and `metric: :statsd` does not use a formatter, so it never calls the block.

~~~ruby
SemanticLogger.add_appender(file_name: "development.log") { |log| "#{log.name} -- #{log.message}" }
SemanticLogger.add_appender(appender: :tcp, server: "localhost:514") { |log| "#{log.level} #{log.message}" }
~~~

A block formats one entry at a time, so it cannot format the single request that `:http`, `:loki`,
and `metric: :signalfx` send for a whole batch when added with `batch: true`: those need a formatter
that implements `#batch(logs, logger)`.

When both a block and `formatter:` are given, the block takes precedence, and `formatter:` is
ignored.

The same formatter can be given to `formatter:` as a Proc, for example to share it between
appenders:

~~~ruby
formatter = proc do |log|
  # This formatter just returns the log event as a string
  log.inspect
end
SemanticLogger.add_appender(io: $stdout, formatter: formatter)
SemanticLogger.add_appender(file_name: "development.log", formatter: formatter)
~~~

An appender created with `new` and added as `appender:` or `metric:` already has its formatter, so
`add_appender` ignores a block given with it, as it does `formatter:`, and reports a
[deprecation warning](upgrading.html#seeing-deprecation-warnings); v6 raises an `ArgumentError`.
Give the block, or `formatter:`, to `new` instead:

~~~ruby
appender = SemanticLogger::Appender::Tcp.new(server: "localhost:514") { |log| "#{log.level} #{log.message}" }
SemanticLogger.add_appender(appender: appender)
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
untrusted log data (the logger name, thread name, message, payload, tags, named tags, the message,
details, and backtrace lines of the logged exception, and the message and backtrace lines of each
exception that caused it) with a printable, escaped form. For example a newline is written as `\n`
and the ANSI escape as `\e`. The Unicode characters that control how text is shown are escaped too,
in the `\uXXXX` form: the C1 control characters (U+0080 to U+009F), the line and paragraph
separators (U+2028, U+2029), at which editors and some log viewers start a new line, and the
bidirectional controls (U+202A to U+202E, U+2066 to U+2069), such as the right-to-left override that
can make logged text read backwards. The option is **disabled by default** to preserve the existing
human readable output:

```ruby
# Text appender that escapes control characters in untrusted data:
SemanticLogger.add_appender(file_name: "production.log", formatter: {default: {escape_control_chars: true}})

# Colorized appender, still escaping control characters in the logged data
# (the formatter's own color codes are preserved):
SemanticLogger.add_appender(io: $stdout, formatter: {color: {escape_control_chars: true}})
```

The option only escapes the control characters in the logged data; it does not touch the formatter's
own decoration, so the `:color` formatter keeps emitting its color codes. It does render the payload
without Amazing Print's colors, and on a single line, since the colors and line breaks Amazing Print
adds cannot be told apart from those in the data. The text formatters still lay out an exception and
its backtrace over several lines, since that layout is generated by Semantic Logger rather than
supplied as log data. The `:syslog` formatter, which escapes control characters by
default, is the exception: it also escapes the newlines between an exception and its backtrace lines,
so that each entry is a single line. The pattern formatter supports the same option (`{pattern:
{pattern: "...", escape_control_chars: true}}`), and the syslog, TCP, and UDP appenders enable it
where appropriate; see [Appenders](appenders.html).

### Exception details

Since Ruby 3.2, Ruby keeps some of the most useful information about an exception out of its
`message`, and adds it in `Exception#detailed_message` instead: did_you_mean suggestions, the
error_highlight snippet that points at the failing call, and any detail an exception class adds by
overriding `#detailed_message`. Semantic Logger logs that detail, without repeating the class name
that Ruby also adds, on the line after the exception message:

~~~
2026-10-25 12:00:00.000000 E [12345:1234 orders.rb:12] Orders -- Failed to ship -- Exception: NoMethodError: undefined method 'upcas' for an instance of String
Did you mean?  upcase
               upcase!
orders.rb:12:in 'Orders#ship'
...
~~~

The `log_exception_details` formatter option controls it:

| Value | Logs |
|-------|------|
| `true` | The detail, without the error_highlight source snippet. |
| `:with_source` | The detail, including the error_highlight source snippet. It is about 100 times slower, because error_highlight re-parses the source file of the failing line, and it copies source code into the log. |
| `false` | No detail. The exception message is unchanged either way. |

It defaults to `true` for the `:default`, `:color`, and `:pattern` formatters, and to `false` for
every other formatter, including `:one_line` and the syslog formatters, so their output does not
change. The syslog appender also turns it off for the formatter it uses with a local syslog daemon.
When enabled, `:one_line` joins the detail onto the same line, after ` -- `. With the `:json`
formatter and the others built on `:raw`, it adds an `exception.details` field (and `details`
within each `cause`), which `:logfmt` writes as `exception_details`:

```ruby
# Include the error_highlight source snippet in development:
SemanticLogger.add_appender(io: $stdout, formatter: {color: {log_exception_details: :with_source}})

# Add exception.details to JSON output:
SemanticLogger.add_appender(file_name: "production.json", formatter: {json: {log_exception_details: true}})
```

The pattern formatter's `%{exception_details}` directive interpolates the detail.

Notes:

* On Ruby 3.2, a `NameError` or `NoMethodError` calls `inspect` on its receiver every time its
  message is built, and logging the detail builds it twice more. If the receivers of logged
  exceptions are slow to inspect, set `log_exception_details: false`. Ruby 3.3 and later do not
  inspect the receiver.
* An exception class that overrides `#detailed_message` without accepting extra keyword arguments
  (`def detailed_message(highlight: false)`) cannot be asked to leave out error_highlight's source
  snippet. When error_highlight decorates that exception (a `NameError`, `TypeError`, or
  `ArgumentError`), its detail is only logged with `:with_source`.

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
  attr_reader :url

  # Add additional arguments to the initializer while supporting all existing ones.
  def initialize(url:, **args, &block)
    super(**args, &block)
    @url = url
  end

  # Display the log struct and the text formatted output
  def log(log)
    # Display the raw log structure
    p log

    # Display the formatted output
    puts format_log(log)
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

Do not give the appender an option of the same name as one that `super` already accepts, such as
`host` or `level`: the appender's own keyword would take the value, so `super` would never receive
it. Call `super` before setting the appender's own instance variables, since `super` sets those of
every appender, such as `@name` and `@host`.

When the appender runs asynchronously (`async: true` or batching), an exception raised by `#log`
discards the message, and the worker thread backs off before writing the next one, on the basis
that the destination may be briefly unavailable. An exception caused by the content of one message
says nothing about the destination, so the thread carries on straight away instead.
`#message_error?(exception)` decides which is which. Format each message with `format_log(log)` (or
a batch with `format_batch(logs)`) rather than `formatter.call`: any error the
formatter raises is then raised as a `SemanticLogger::Subscriber::FormatError`, which
`#message_error?` recognizes, since a formatter can only fail because of the content of the message.
By default it also recognizes the errors raised when serializing a value that cannot be written
(`JSON::GeneratorError`, `JSON::NestingError`, `EncodingError`, and `FloatDomainError`). Override it
to recognize errors your appender's client raises for content it cannot write:

~~~ruby
def message_error?(exception)
  exception.is_a?(MyClient::InvalidDocument) || super
end
~~~

A `SystemStackError` is handled separately: the message is discarded, and since a thread must not
overflow its stack twice (on macOS that crashes Ruby), the worker carries on in a new thread. Do not
rescue it in `#log` or `#batch`.

An appender that supports batching implements `#batch(logs)`. When `#batch` raises a message error,
the whole batch is discarded by default, since it may already have written some of the messages.
If `#batch` writes nothing unless every message can be written, for example because it formats
them all into one request before sending it, return `true` from `#batch_all_or_nothing?`. The batch
is then split up and retried, so that only the offending message is discarded:

~~~ruby
def batch(logs)
  client.send_all(logs.map { |log| format_log(log) })
end

def batch_all_or_nothing?
  true
end
~~~

Register the appender by passing an instance to `add_appender`:

~~~ruby
SemanticLogger.add_appender(appender: SimpleAppender.new(url: "https://logs.example.com"))
~~~

Give the instance its own options, such as `level:` and `formatter:`, and a formatter block, when
creating it, since `add_appender` adds it as it is. Only the options of `add_appender` itself, such as
`async:` and `batch:`, apply to an instance:

~~~ruby
appender = SimpleAppender.new(url: "https://logs.example.com", level: :warn, formatter: :json)
SemanticLogger.add_appender(appender: appender, async: true)
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

### Changing an appender while running

Keep the appender returned by `add_appender` to change its level or formatter later, without
restarting the application. The formatter accepts the same values as the `formatter:` option:

~~~ruby
console = SemanticLogger.add_appender(io: $stdout, formatter: :color)

# ... later
console.level     = :debug
console.formatter = :json
~~~

An appender that formats its messages as one batch, such as `:http` or `:loki` with `batch: true`,
needs a formatter that implements `#batch(logs, logger)`, such as `:json`.

Messages are formatted as they are written. When the appender runs asynchronously, messages still
on its queue are written with the new formatter. Call `SemanticLogger.flush` just before changing it
so that messages logged before the flush keep the old one.

Only one appender may write to each of `$stdout` and `$stderr`, since a second one would duplicate
every line, so `add_appender` ignores (and warns about) a second appender for the same console
stream, and returns `nil`. To change how the console output looks, find the existing appender and
change its formatter as above:

~~~ruby
console = SemanticLogger.appenders.find { |appender| appender.console_stream == :stdout }
console&.formatter = :json
~~~

`find` returns `nil` when no appender writes to that stream.

Or remove it with `SemanticLogger.remove_appender(console)` and then add the new one.

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
available to appenders and formatters as `log.context`, and formatters that write the context, such
as `:loki`, write it too. To hand an appender of your own an object it needs from the logging thread
that is not log data, such as a client's current scope, use `log.capture(key, value)` instead, and
read it in the appender with `log.captured(key)`: formatters do not write it, unless one is built
for that appender and reads its key.
