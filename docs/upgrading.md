---
layout: default
---

## Upgrading

### Upgrading to Semantic Logger v5.0

#### `SemanticLogger::Appender::AsyncBatch` has been removed

The internal asynchronous proxy classes have been consolidated. Batch processing now runs through
the same `SemanticLogger::Appender::Async` proxy (backed by an internal `QueueProcessor`), so the
separate `SemanticLogger::Appender::AsyncBatch` class no longer exists.

This only affects code that referenced the class directly, which is uncommon since appenders are
added through `SemanticLogger.add_appender`. The `batch:`, `batch_size:`, and `batch_seconds:`
options are unchanged:

~~~ruby
SemanticLogger.add_appender(appender: :http, url: "https://example.com/log", batch: true)
~~~

What changed:

- `SemanticLogger.add_appender(..., batch: true)` now returns a `SemanticLogger::Appender::Async`
  (with `#batch?` returning `true`) instead of a `SemanticLogger::Appender::AsyncBatch`.
- Referencing the constant `SemanticLogger::Appender::AsyncBatch` now raises `NameError`.

If you have a custom appender or test asserting on the proxy class, change
`instance_of?`/`is_a?(SemanticLogger::Appender::AsyncBatch)` checks to
`SemanticLogger::Appender::Async` and, if needed, check `appender.batch?`.

### Upgrading to Semantic Logger v4.18

#### Async queue is now bounded by default

The default `max_queue_size` for async appenders changed from `-1` (unbounded) to `10_000`.
Under sustained high log volume, messages that exceed the queue limit will be dropped rather than
causing memory to grow without bound.

If your application logs at very high throughput and you were relying on the unbounded default,
set the limit explicitly when adding each appender:

~~~ruby
SemanticLogger.add_appender(io: $stdout, async: true, max_queue_size: -1)
~~~

Alternatively, tune the value to match your application's tolerance for log loss vs. memory usage.

#### Invalid exception values are now wrapped

Previously, passing a non-`Exception` object to the `exception:` keyword argument would silently
misbehave. It is now wrapped in an `ArgumentError` with a description of the invalid value and a
backtrace pointing to the call site:

~~~ruby
# This previously caused undefined behaviour — now raises a descriptive ArgumentError
logger.error("Something went wrong", exception: "a plain string")
~~~

#### New Relic formatter — trace and span metadata

Previously, New Relic trace metadata (`trace.id`, `span.id`, `entity.name`, etc.) was captured at
format time, so it worked with any appender type. In v4.18, this metadata is captured via an
`on_log` callback that is only registered when `SemanticLogger::Appender::NewRelicLogs` is
instantiated.

If you use a plain IO or File appender with `SemanticLogger::Formatters::NewRelicLogs` as the
formatter (rather than the dedicated `NewRelicLogs` appender), you must register the callback
manually in your initializer, otherwise `trace.id`, `span.id`, and `entity.name` will be absent
from all logs:

~~~ruby
require "semantic_logger/appender/new_relic_logs"
SemanticLogger.on_log(SemanticLogger::Appender::NewRelicLogs::CAPTURE_CONTEXT)
~~~

This line should be added before any log messages are emitted.

---

### Upgrading to Semantic Logger v4.17

#### New Relic formatter (breaking changes for New Relic users)

The New Relic log formatter (`SemanticLogger::Formatters::NewRelicLogs`) has been significantly
updated to produce a structure that New Relic can natively parse and index as individual
attributes. Most users will benefit from richer log correlation in New Relic, but there are
several breaking changes to be aware of.

##### Log output structure

Previously, all semantic fields (`payload`, `tags`, `named_tags`, `metric`, etc.) were serialized
as a JSON string inside the `message` key. They are now emitted as top-level keys:

Before (v4.16):
~~~json
{
  "message": "{\"message\":\"Order processed\",\"payload\":{\"order_id\":123},\"tags\":[],\"named_tags\":{}}",
  "timestamp": 1234567890000,
  "log.level": "INFO"
}
~~~

After (v4.17):
~~~json
{
  "message": "Order processed",
  "payload": { "order_id": 123 },
  "timestamp": 1234567890000,
  "logger": { "name": "OrderService" },
  "thread": { "name": "main" }
}
~~~

**Impact**: Any New Relic alert queries, dashboards, or NRQL that references fields inside the
old `message` JSON string (e.g. `message.payload.order_id`) must be updated to reference the
new top-level keys (e.g. `payload.order_id`).

Note that New Relic's log ingestion flattens nested objects. A `payload` value that is itself a
nested Hash may not be fully indexed as individually searchable attributes. If you need payload
fields to be queryable in New Relic, promote them to `named_tags` instead:

~~~ruby
# Payload fields may not be individually queryable in New Relic:
logger.info "Order processed", order_id: 123, amount: 49.99

# Use named_tags for fields you want to query directly in New Relic:
SemanticLogger.tagged(order_id: 123, amount: 49.99) do
  logger.info "Order processed"
end
~~~

##### named_tags are now merged to the top level

Previously `named_tags` were nested inside the `message` JSON string. They are now merged
directly into the top-level log entry, making them first-class attributes in New Relic.

If a named tag key conflicts with an existing top-level key (e.g. `message`, `timestamp`), it is
dropped and the conflicting key names are recorded under `named_tag_conflicts`.

##### Error, logger, and thread fields restructured

Before (v4.16):
~~~json
{
  "error.message": "Something went wrong",
  "error.class":   "RuntimeError",
  "error.stack":   "...",
  "log.level":     "ERROR",
  "logger.name":   "OrderService",
  "thread.name":   "main"
}
~~~

After (v4.17):
~~~json
{
  "error":  { "message": "Something went wrong", "class": "RuntimeError", "stack": "..." },
  "logger": { "name": "OrderService" },
  "thread": { "name": "main" }
}
~~~

Update any New Relic alert conditions or NRQL queries that reference the old dot-notation keys.

#### Suppressing timestamps in formatters

v4.17 added `:notime` as an explicit `time_format` value to suppress timestamp output. If you
were previously passing `time_format: nil` expecting it to suppress output, use `:notime` instead:

~~~ruby
SemanticLogger.add_appender(io: $stdout, formatter: MyFormatter.new(time_format: :notime))
~~~

---

### Upgrading to Semantic Logger v4.9

These changes should not be noticeable by the majority of users of Semantic Logger, since
they are to the internal API. It is possible that advanced users may be using these internal
API's directly.

This does not affect any calls to the public api `SemanticLogger.add_appender`.

File and IO are now separate appenders. When creating the File appender explicitly, its arguments
have changed. For example, when requesting an IO stream, it needs to be changed from:

~~~ruby
SemanticLogger::Appender::File.new(io: $stderr)
~~~
to:
~~~ruby
SemanticLogger::Appender::IO.new($stderr)
~~~

Additionally, this needs to be changed from:
~~~ruby
SemanticLogger::Appender::File.new(file_name: "file.log")
~~~
to:
~~~ruby
SemanticLogger::Appender::File.new("file.log")
~~~

Rails Semantic Logger, if used, needs to be upgraded to v4.9 when upgrading to Semantic Logger v4.9.

---

### Upgrading to Semantic Logger v4.4

With some forking frameworks it is necessary to call `reopen` after the fork. With v4.4 the
workaround for Ruby 2.5 crashes is no longer needed.
I.e. Please remove the following line if being called anywhere:

~~~ruby
SemanticLogger::Processor.instance.instance_variable_set(:@queue, Queue.new)
~~~

---

### Upgrading to Semantic Logger v4.0

The following changes need to be made when upgrading to V4:
- Ruby V2.3 / JRuby V9.1 is now the minimum runtime version.
- Replace calls to `Logger#with_payload` with `SemanticLogger.named_tagged`.
- Replace calls to `Logger#payload` with `SemanticLogger.named_tags`.
- MongoDB Appender requires Mongo Ruby Client V2 or greater.
- Appenders now write payload data in a separate `:payload` tag instead of mixing them
  directly into the root elements to avoid name clashes.

As a result any calls like the following:

~~~ruby
logger.debug foo: 'foo', bar: 'bar'
~~~

Must be replaced with the following in v4:

~~~ruby
logger.debug payload: {foo: 'foo', bar: 'bar'}
~~~

Similarly, for measure blocks:

~~~ruby
logger.measure_info('How long is the sleep', foo: 'foo', bar: 'bar') { sleep 1 }
~~~

Must be replaced with the following in v4:

~~~ruby
logger.measure_info('How long is the sleep', payload: {foo: 'foo', bar: 'bar'}) { sleep 1 }
~~~

The common log call has not changed, and the payload is still logged directly:

~~~ruby
logger.debug('log this', foo: 'foo', bar: 'bar')
~~~
