---
layout: default
title: Log Event
description: >-
  The Log event object that carries every entry through the pipeline: which
  fields are always present, its attributes and helper methods, and how to
  inspect one.
---


**Contents**

* TOC
{:toc}

Every call to a logger (`logger.info`, `logger.measure_error`, and so on) builds a single **Log
event** object. That object is the unit of work that flows through the whole pipeline: it is
handed to each [filter](config.html#filtering), then to each appender's [formatter](config.html#custom-formatters), and
finally written out by the [appender](appenders.html) itself, usually on a background thread so the
calling application is not blocked.

You meet the Log event whenever you customize Semantic Logger:

* A **filter** Proc receives it and returns `true` to keep the entry. See [Filtering](config.html#filtering).
* A **formatter** receives it and turns it into the final output (text, JSON, ...). See [Custom formatters](config.html#custom-formatters).
* A custom **appender**'s `#log(log)` method receives it and writes it to a destination.

In every one of those places you are reading the same object documented here.

### The event is mutable

The Log event is a plain mutable Ruby object: every attribute below has both a reader and a
writer. All appenders share one event instance per log call, so change it only before it is handed
to them: in an [`on_log`](config.html#capturing-context-with-on_log) subscriber, which runs for
every entry, or in the `filter` of a logger instance, which runs for that logger's entries. For
example, to add context to every entry:

```ruby
SemanticLogger.on_log do |log|
  log.set_context(:request_id, Thread.current[:request_id])
end
```

To redact sensitive data, see [Redacting sensitive data](security.html#redacting-sensitive-data).

Do not change the event in an appender's `filter` or in a formatter: the appenders that ran before
it have already written the event, and one that runs asynchronously may be reading it on its own
thread at the same time.

### Which fields are always present

A handful of attributes are populated for **every** event:

* `level`, `level_index`, `name`, `time`, `thread_name`, `tags`, `named_tags`.

The rest are **situational**: they are set only when relevant to that particular call. For example
`duration` is present only for `measure_*` calls, `exception` only when an exception was logged,
`metric`/`metric_amount`/`dimensions` only for metrics, `backtrace` only when backtrace
capture is enabled (`SemanticLogger.backtrace_level`), and `call_site` only when call site recording
is enabled (`SemanticLogger.call_site_level`). Always guard against `nil` when reading a
situational field.

### Attributes

|Attribute|Type|Description|
|---------|----|-----------|
|`level`|`Symbol`|Log level of the call: `:trace`, `:debug`, `:info`, `:warn`, `:error`, `:fatal`.|
|`level_index`|`Integer`|Numeric form of the level for fast comparisons: `:trace=>0`, `:debug=>1`, `:info=>2`, `:warn=>3`, `:error=>4`, `:fatal=>5`.|
|`name`|`String`|Class or component name supplied to the logger, for example the `"MyClass"` in `SemanticLogger["MyClass"]`.|
|`message`|`String`|The text message. May be `nil` (for example, a metric-only event).|
|`payload`|`Hash`|Structured data logged alongside the message. `nil` when none was supplied.|
|`time`|`Time`|The moment the event was created.|
|`thread_name`|`String`|Name (or id) of the thread that made the log call.|
|`tags`|`Array<String>`|Tags active on the thread when the call was made.|
|`named_tags`|`Hash<String, Object>`|Named tags active on the thread when the call was made.|
|`context`|`Hash`|Named contexts captured in-line at the point the event was created. `nil` when none.|
|`captures`|`Hash`|Objects an appender captured in-line for its own use, such as the OpenTelemetry context. Unlike `context`, formatters do not write them, except one built for that appender, as `:new_relic_logs` writes the linking metadata its appender captures. `nil` when none.|
|`duration`|`Float`|Time in milliseconds taken by a `measure_*` call. `nil` for ordinary log calls.|
|`exception`|`Exception`|The Ruby exception that was logged. `nil` when none. Use `each_exception` to walk a `cause` chain.|
|`backtrace`|`Array<String>`|Backtrace captured at the call site, present only when the level is at or above `SemanticLogger.backtrace_level`.|
|`call_site`|`SemanticLogger::CallSite`|Where the entry was logged, present only when the level is at or above `SemanticLogger.call_site_level`, and the log call did not pass `call_site: false`. See [The call site](#the-call-site).|
|`metric`|`String`|The metric name, present for metric and `measure_*` calls. See [Metrics](metrics.html).|
|`metric_amount`|`Numeric`|Amount to add to a counter metric, for example the quantity purchased. A counter adds 1 when it is `nil`. A negative amount is still logged, but once a metric appender is present its metric is dropped, with a warning on the internal logger, see [Negative metric amounts](upgrading.html#negative-metric-amounts).|
|`dimensions`|`Hash`|Dimensions (key/value labels) supplied for a metric.|

### The call site

`call_site` is a frozen value object that records where the entry was logged. See
[Recording where each entry was logged](config.html#recording-where-each-entry-was-logged) for how
it is found.

|Method|Returns|Description|
|------|-------|-----------|
|`path`|`String`|The file, as in a backtrace, for example `"/app/models/order.rb"`.|
|`line`|`Integer`|The line number in the file.|
|`label`|`String` or `nil`|The label Ruby gives the frame, usually the method: `"Order#submit"` on Ruby 3.4 and later, `"submit"` on Ruby 3.2, 3.3, and JRuby.|
|`file_name_and_line(short_name: false)`|`[String, Integer]`|The path and line. With `short_name: true` the file name has no directory, for example `"order.rb"`.|
|`to_s`|`String`|The call site as a backtrace line, for example `"/app/models/order.rb:42:in 'Order#submit'"`.|

~~~ruby
class MyFormatter
  def call(log, _logger)
    site = log.call_site
    location = site ? " (#{site.label} at #{File.basename(site.path)}:#{site.line})" : ""
    "#{log.level_to_s} #{log.name} -- #{log.message}#{location}"
  end
end
~~~

### Helper methods

These read-only helpers derive convenient values from the attributes above:

|Method|Returns|Description|
|------|-------|-----------|
|`payload?`|`true`/`false`|Whether the event carries a non-empty payload.|
|`dimensions?`|`true`/`false`|Whether the event has a metric with dimensions, a `Hash` that is not empty. The formatters write the dimensions only then.|
|`payload_to_s`|`String` or `nil`|The payload rendered with `inspect`, or `nil` when absent.|
|`metric_only?`|`true`/`false`|`true` when the event has a metric but no message and no exception. Metric subscribers receive these; log appenders leave them out unless their `metrics` option is true, the default only for `:kafka`, `:rabbitmq`, and `:udp` until v6. See [Metrics in log appenders](metrics.html#metrics-in-log-appenders).|
|`duration_to_s`|`String` or `nil`|The duration in milliseconds as a short string, for example `"12ms"`. `nil` when there is no duration.|
|`duration_human`|`String` or `nil`|The duration in human readable form, scaling up to seconds, minutes, hours, or days as needed.|
|`level_to_s`|`String`|The level as a single upper-case character, for example `"I"` for `:info`.|
|`cleansed_message`|`String`|The message with Rails/ANSI color escape codes stripped. Used to keep terminal codes out of structured output.|
|`each_exception`|Enumerator|Iterates the exception and its nested `cause` chain, yielding `(exception, depth)`.|
|`backtrace_to_s(cleaner: nil)`|`String`|The exception backtrace as a string, including every exception in the `cause` chain. Lines are separated by a line break, with none before the first or after the last, so put your own line break before it. With a block, each cause's message and each backtrace line is replaced by the value the block returns, for example to escape it. With a `cleaner`, each backtrace is first cleaned as `backtrace_of` cleans it. Each cause is written as `Cause: Class: message`, with the class named as Ruby names it in `Exception#inspect`: the constant it was assigned to, even when the class overrides `self.name`, or for an anonymous class the class as Ruby writes it, such as `#<Class:0x000...>`. A cause's message, as written and as passed to the block, is always a `String`: when its `#message` raises, the message it was raised with is used instead, and a `nil` message is empty. Text in encodings that cannot be joined, such as a binary message and a UTF-8 backtrace line, is joined as UTF-8, and so are binary or US-ASCII backtrace lines that hold bytes outside ASCII, such as Ruby's own where no locale is set in a directory such as `café`, which would otherwise make the whole text binary or invalid US-ASCII.|
|`backtrace_of(exception, cleaner: nil)`|`Array<String>` or `nil`|The backtrace of `exception` (this event's exception or one of its causes). With a [backtrace cleaner](config.html#cleaning-backtraces) object, such as `Rails.backtrace_cleaner` (not `true`, as the formatter option accepts), the lines it keeps, or the full backtrace when it keeps none; the exception is not changed. A cleaned backtrace, and each of its lines, is frozen and cached on the event.|
|`exception_details(exception, source: false)`|`String` or `nil`|The detail Ruby's `Exception#detailed_message` adds to the message of `exception` (this event's exception or one of its causes), such as did_you_mean suggestions, without the class name. `source: true` also includes error_highlight's source snippet. `nil` when there is none. Cached on the event.|
|`file_name_and_line(short_name = false)`|`[String, Integer]` or `nil`|The file name and line number from the event's call site, or else its backtrace or exception. Pass `true` for just the base file name.|
|`to_h`|`Hash`|The event as a plain Hash (via the Raw formatter), including `host`, `application`, and `environment`. Handy for inspecting an event or building a custom formatter.|
|`set_context(key, value)`|`Object`|Lazily initializes `context`, stores a key/value pair on it, and returns the value.|
|`capture(key, value)`|`Object`|Lazily initializes `captures`, stores a key/value pair on it, and returns the value, for an appender that needs state of the logging thread, such as the current trace, that is not log data.|
|`captured(key)`|`Object` or `nil`|The value captured with `key`, or `nil` when there is none.|

### Inspecting an event

When writing a filter or formatter, the quickest way to see what a real event contains is to dump
it with `to_h`:

```ruby
SemanticLogger.add_appender(
  io:     $stdout,
  filter: ->(log) do
    pp log.to_h   # one-off: inspect the event during development
    true
  end
)
```
