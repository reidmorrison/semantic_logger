---
layout: default
---

## Log Event
{:.no_toc}

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

In every one of those places you are reading (and may modify) the same object documented here.

### The event is mutable

The Log event is a plain mutable Ruby object: every attribute below has both a reader and a
writer. Filters and formatters are allowed to change it before it is written, for example to
redact a message or enrich the payload:

```ruby
filter: ->(log) do
  log.message = log.message.gsub(/\d{16}/, "[REDACTED]")
  true # keep the (now edited) entry
end
```

Because all appenders share one event instance per log call, keep any mutation deliberate: a
change made in a filter is visible to every appender that runs afterwards.

### Which fields are always present

A handful of attributes are populated for **every** event:

* `level`, `level_index`, `name`, `time`, `thread_name`, `tags`, `named_tags`.

The rest are **situational**: they are set only when relevant to that particular call. For example
`duration` is present only for `measure_*` calls, `exception` only when an exception was logged,
`metric`/`metric_amount`/`dimensions` only for metrics, and `backtrace` only when backtrace
capture is enabled (`SemanticLogger.backtrace_level`). Always guard against `nil` when reading a
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
|`duration`|`Float`|Time in milliseconds taken by a `measure_*` call. `nil` for ordinary log calls.|
|`exception`|`Exception`|The Ruby exception that was logged. `nil` when none. Use `each_exception` to walk a `cause` chain.|
|`backtrace`|`Array<String>`|Backtrace captured at the call site, present only when the level is at or above `SemanticLogger.backtrace_level`.|
|`metric`|`String`|The metric name, present for metric and `measure_*` calls. See [Metrics](metrics.html).|
|`metric_amount`|`Float`|Numeric amount for a counter or gauge metric, for example the quantity purchased.|
|`dimensions`|`Hash`|Dimensions (key/value labels) supplied for a metric.|

### Helper methods

These read-only helpers derive convenient values from the attributes above:

|Method|Returns|Description|
|------|-------|-----------|
|`payload?`|`true`/`false`|Whether the event carries a non-empty payload.|
|`payload_to_s`|`String` or `nil`|The payload rendered with `inspect`, or `nil` when absent.|
|`metric_only?`|`true`/`false`|`true` when the event has a metric but no message and no exception. Text appenders typically skip these; machine-readable (JSON) appenders usually keep them.|
|`duration_to_s`|`String` or `nil`|The duration in milliseconds as a short string, for example `"12ms"`. `nil` when there is no duration.|
|`duration_human`|`String` or `nil`|The duration in human readable form, scaling up to seconds, minutes, hours, or days as needed.|
|`level_to_s`|`String`|The level as a single upper-case character, for example `"I"` for `:info`.|
|`cleansed_message`|`String`|The message with Rails/ANSI color escape codes stripped. Used to keep terminal codes out of structured output.|
|`each_exception`|Enumerator|Iterates the exception and its nested `cause` chain, yielding `(exception, depth)`.|
|`backtrace_to_s`|`String`|The exception backtrace as a string, including every exception in the `cause` chain.|
|`file_name_and_line(short_name = false)`|`[String, Integer]` or `nil`|The file name and line number from the event's backtrace or exception. Pass `true` for just the base file name.|
|`to_h`|`Hash`|The event as a plain Hash (via the Raw formatter), including `host`, `application`, and `environment`. Handy for inspecting an event or building a custom formatter.|
|`set_context(key, value)`|`Hash`|Lazily initializes `context` and stores a key/value pair on it.|

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
