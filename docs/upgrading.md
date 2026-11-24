---
layout: default
title: Upgrading
description: >-
  Version-by-version upgrade notes for Semantic Logger, from v4.0 through the
  v6 level-independent metrics.
---


**Contents**

* TOC
{:toc}

### Seeing deprecation warnings

Semantic Logger reports the use of a deprecated appender or option as a Ruby deprecation warning, the
same way that Ruby reports its own, naming the line of your application that used it, and what to use
instead. For example, v5 reported:

~~~
config/initializers/logging.rb:12: warning: SemanticLogger: SemanticLogger::Appender::Sentry (appender: :sentry) is deprecated and will be removed in v6. It depends on the end-of-life sentry-raven gem. Use appender: :sentry_ruby instead.
~~~

When a gem adds the appender for you, the warning names the line of that gem that added it. A
warning about a log entry that an appender reports while it writes the entry, on Semantic Logger's
background thread, names no line, since your code is not on that thread; to see the line, run with
`SemanticLogger.sync!`, as tests often do.

Ruby only shows deprecation warnings while `Warning[:deprecated]` is true, which it is not by default,
so production stays quiet without any configuration:

| Where | Deprecation warnings |
|-------|----------------------|
| Tests run with Minitest or test-unit | On, since both turn them on |
| Tests run with RSpec | Off, unless run with `rspec --warnings`, or `Warning[:deprecated] = true` is set in `spec_helper.rb` |
| Development | Off, unless `RUBYOPT=-W:deprecated` is set in the environment, or `Warning[:deprecated] = true` in code that only runs in development, such as `config/environments/development.rb` |
| Production | Off |

Rails settings such as `config.active_support.deprecation` only apply to the deprecation warnings of
Rails, not to those that Ruby reports.

Ruby writes each warning to `$stderr`. To send them elsewhere, such as to a file of their own, or to
raise them in your tests so that each use is found, extend `Warning` with your own `warn`:

~~~ruby
module SemanticLoggerDeprecations
  DEPRECATIONS = ::Logger.new("log/deprecations.log")

  def warn(message, *, **)
    return super unless message.include?("SemanticLogger: ")

    DEPRECATIONS.warn(message.chomp)
  end
end
Warning.extend(SemanticLoggerDeprecations)
~~~

Do not log them through Semantic Logger itself: a warning reported on its background thread would
then wait on that thread's own queue, which can stop all logging while the queue is full.

### Upgrading to Semantic Logger v6

v6 is not released yet. These notes cover its metrics changes, and the removal of what v5
deprecated, each in a section below. Before upgrading, run your application, or its tests, on the
latest v5 with deprecation warnings on (see [Seeing deprecation warnings](#seeing-deprecation-warnings)),
and fix each one that it reports.

#### Metrics no longer depend on the log level

Once a metric appender is added, such as `add_appender(metric: :statsd)`, the `metric:` of a log
call or a `measure_*` call is recorded at every level, and whether or not its `min_duration:` is
met. In v5 it was sent only with a log entry that was logged. The log entry itself still follows
the log level and filters, as before.

So a metric on a `:debug` or `:trace` call, which stayed dormant under an `:info` level in v5, is
now recorded, and a `measure_*` call with a `min_duration:` and a `metric:` now records every
duration, not only those over the minimum. Expect higher counts for such metrics, and remove a
`metric:` that should not be recorded. To time code for metrics alone, use the new metric calls,
which log nothing:

~~~ruby
logger.increment("users.signup")
logger.time("supplier.add_user") { supplier.add_user(user) }
logger.time("sidekiq.queue.latency", duration: latency_ms)
logger.record("upload.size", file.size, unit: "By")
~~~

Below the level, a `measure_*` call times its block for its metric only when the `metric:` is in its
options before the call: a metric that the block adds to the options is recorded only when the level
passes. See [Metrics](metrics.html#metrics-on-log-and-measure-calls).

Without a metric appender, nothing changes: a `metric:` is only part of its log entry.

#### Metric appenders write once per interval, and take no log entries

The `:statsd`, `:new_relic`, and `:signalfx` metric appenders no longer receive log entries. Metrics
are aggregated in the process, and each metric appender is given a snapshot of each interval,
`interval:` seconds, 60 by default, which it sends at once:

* `:statsd` sends one counter packet per metric name per interval, rather than one per call, and a
  histogram as one timer packet per bucket, with a sample rate. See
  [StatsD](metrics.html#statsd).
* `:new_relic` records a counter with one `increment_metric` per interval, and a histogram with one
  pre-aggregated `record_metric`, rather than one call per log entry. See
  [New Relic](metrics.html#new-relic).
* `:signalfx` posts one request per interval, with a counter for each counter series, and for each
  histogram the counters `<name>.count` and `<name>.sum` and the gauges `<name>` (the mean),
  `<name>.min`, `<name>.max`, `<name>.p50`, `<name>.p95`, and `<name>.p99`. A metric's own dimension
  named `host`, `application`, or `environment` is kept, rather than replaced by the appender's. See
  [SignalFx](metrics.html#signalfx).

Pass `interval: 10`, for example, to send more often. `SemanticLogger.flush`, and the flush at exit,
sends what was recorded so far.

#### Options that now raise `ArgumentError`

A metric appender takes no log entries, so the options for log entries raise `ArgumentError` when
given to `:statsd`, `:new_relic`, `:signalfx`, `:otlp`, or a custom metric appender:

| Option | Instead |
|--------|---------|
| `level:` | Remove it: metrics are recorded whatever the log level. `:summary` keeps `level:`, the level of the entries it writes. |
| `filter:` | Remove it: every metric recorded is written. To keep a metric away from an appender, do not record it, or record it under another name. A filter such as `->(log) { !log.dimensions? }`, which kept the metrics with dimensions out of `:statsd` or `:new_relic`, is no longer needed to keep the counts apart: they record the series of a metric together, under its name. |
| `formatter:`, or a formatter block | Remove it: each appender writes metrics in the format of its destination. To change what is sent, write a [custom metric appender](metrics.html#write-a-custom-metric-appender). |
| `batch: true` | Remove it: there are no log entries to batch, and each interval is already sent at once. |
| `dimensions:` of `:signalfx` | Remove it: it listed the named tags to send as dimensions, but named tags are never part of a metric's series. Give the dimensions to the metric call, such as `logger.increment("filters", dimensions: {plan: "premium"})`. |

An option given as `nil` sets nothing, so it is not refused.

#### `SemanticLogger::Formatters::Signalfx` has been removed

`:signalfx` builds its request itself. Remove a `formatter:` that named or subclassed
`SemanticLogger::Formatters::Signalfx`; to send something else, write a
[custom metric appender](metrics.html#write-a-custom-metric-appender).

#### SignalFx metric names

In v5, a metric without dimensions whose name had no `/`, such as `users.signup`, was sent as
`Application.counter` (or `Application.average` for a duration), with the dimensions
`class: "Unknown"` and `action: "users.signup"`. It is now sent under its own name, `users.signup`,
so move the charts and detectors that matched it on `Application.counter` with `class: "Unknown"`
to the new name. A metric with dimensions is still sent under its own name, and one without
dimensions whose name has a `/`, such as `Common/User/authorize`, is still sent as
`Application.counter` and `Application.average`, with `class` and `action` dimensions taken from
its name.

A histogram's mean is now sent with the gauges `<name>.min`, `<name>.max`, and the percentiles, and
its count as the counter `<name>.count` (`Application.counter` for a `Class/action` name), so a
counter you record as `<name>.count` is added to the count of the histogram `<name>`, and a counter
you record as `<name>.max`, for example, keeps the gauge `<name>.max` of the histogram with the same
dimensions out of the request, with a warning on the internal logger.

#### Metric dimensions are redacted

`SemanticLogger.sensitive_keys=` now also redacts the dimensions of the metrics given to the metric
appenders: the value of a dimension whose key is sensitive is replaced, such as with
`"[FILTERED]"`, and the series that differed only by that value are merged into one. Keys are never
replaced. See [Metric dimensions](security.html#metric-dimensions).

#### Negative metric amounts are dropped

A negative `metric_amount`, deprecated in v5.3, is now dropped: the log entry is still written with
it, but its metric is not recorded, and the internal logger warns once per metric name. So is a
negative amount given to `logger.increment`. Count what goes down as a metric of its own, such as
`cart.items_removed`. v6.0 has no gauge for a value that goes up and down.

#### A failed `measure_*` call adds `error.type` to its metric

When the block of a `measure_*` call that has a `metric:` raises, its metric gets the dimension
`"error.type"`, the class name of the exception, as the OpenTelemetry semantic conventions name it,
unless its `dimensions:` already have one (an anonymous exception class is named after its nearest
named superclass). Failed calls are then a series of their own: the totals
across series are unchanged, but a chart or alert that selects the series by all of its dimensions
no longer counts the failures. The log entry keeps its own dimensions.

#### Custom metric subscribers

A metric subscriber of your own that implements `#log`, as in v5, is a log appender in v6: it still
receives the log entries that pass its level and filters, so its metrics still follow the log level,
and it is never given the metrics of `increment`, `time`, and `record`. To receive every metric,
include `SemanticLogger::Metric::Snapshots` and implement `write_metrics(snapshot)` instead. See
[Write a custom metric appender](metrics.html#write-a-custom-metric-appender).

#### Send log entries to OpenTelemetry with `appender: :otlp`

`appender: :otlp` sends log entries to an OpenTelemetry collector, or any other OTLP/HTTP receiver,
without any OpenTelemetry gems, and is the documented way to send them to OpenTelemetry (see
[OpenTelemetry over OTLP/HTTP](appenders.html#otlp)). Replace `appender: :open_telemetry`, which
needs the OpenTelemetry logs SDK and its exporter, with it:

~~~ruby
SemanticLogger.add_appender(appender: :otlp)
~~~

It reads the standard `OTEL_EXPORTER_OTLP_*` variables, such as `OTEL_EXPORTER_OTLP_ENDPOINT`, so
`OpenTelemetry::SDK.configure` is no longer needed for logging. A Hash in the payload is flattened
into dotted attribute names, such as `order.address.zip_code`, rather than sent as JSON text.

#### `metric: :otlp` sends http/protobuf by default

In `6.0.0.beta1`, `metric: :otlp` sent OTLP/JSON. It now sends OTLP's binary Protobuf encoding by
default, as the OpenTelemetry specification asks, without the `google-protobuf` gem. Every OTLP/HTTP
receiver accepts it. To keep sending OTLP/JSON, add `protocol: "http/json"`, or set
`OTEL_EXPORTER_OTLP_METRICS_PROTOCOL=http/json`.

#### The `:sentry` appender has been removed

`appender: :sentry`, which depended on the end-of-life `sentry-raven` gem and was deprecated in
v5.1, has been removed. Use `appender: :sentry_ruby` with the `sentry-ruby` gem instead, as shown
in [Replace the `:sentry` appender with `:sentry_ruby`](#replace-the-sentry-appender-with-sentry_ruby).

#### The `:new_relic` appender has been removed

`appender: :new_relic`, which sent `:error` and `:fatal` entries to New Relic as error events and was
deprecated in v5.1, has been removed. Use `appender: :new_relic_logs` instead, which forwards log
entries to New Relic Logs, as shown in
[Replace the `:new_relic` appender with `:new_relic_logs`](#replace-the-new_relic-appender-with-new_relic_logs).
The `:new_relic` metric appender, `add_appender(metric: :new_relic)`, is not affected.

#### The `:splunk` appender has been removed

`appender: :splunk`, which depended on the `splunk-sdk-ruby` gem (last released in 2015, and never
verifying the server's certificate) and was deprecated in v5.2, has been removed. Use the HTTP Event
Collector with `appender: :splunk_http` instead, as shown in
[Replace the `:splunk` appender with `:splunk_http`](#replace-the-splunk-appender-with-splunk_http).

Adding any of these three appenders raises `ArgumentError`, saying that it was removed and naming its
replacement.

#### The Elasticsearch and OpenSearch `type:` option has been removed

The `type:` option of the `:elasticsearch`, `:elasticsearch_http`, and `:opensearch` appenders, ignored
and deprecated since v5.1 since document `_type` has been unused since Elasticsearch 7, has been
removed. Remove it: `:elasticsearch_http` now raises `ArgumentError` for it, and `:elasticsearch` and
`:opensearch` hand it to their client gem with their other options. See
[Remove the `type:` option from the Elasticsearch and OpenSearch appenders](#remove-the-type-option-from-the-elasticsearch-and-opensearch-appenders).

#### `:sentry_ruby` takes the Sentry user and fingerprint from named tags only

The `:sentry_ruby` appender no longer takes the Sentry user (`user_id`, `username`, `user_email`,
`ip_address`, and `user`) or the `fingerprint` from the payload, as deprecated in v5.2, since the
payload can hold untrusted data, such as a request body. They are sent with the rest of the payload,
as extras. Set them with named tags, as shown in
[Set the Sentry user and fingerprint with named tags](#set-the-sentry-user-and-fingerprint-with-named-tags).

#### `:kafka`, `:rabbitmq`, and `:udp` leave out metric-only entries by default

The `:kafka`, `:rabbitmq`, and `:udp` appenders no longer send metric-only entries by default, such
as `logger.info(metric: "users/signup")`, which have a metric but no message and no exception: they
leave them out, as the other log appenders do, and as v5.3 warned. To keep sending them, add the
appender with `metrics: true`. A `metrics: false` added to silence the v5.3 warning can stay, or be
removed. See [Choose `metrics:` for the `:kafka`, `:rabbitmq`, and `:udp` appenders](#choose-metrics-for-the-kafka-rabbitmq-and-udp-appenders).

#### Options given with an appender instance raise `ArgumentError`

`add_appender(appender: instance)` and `add_appender(metric: instance)` now raise `ArgumentError`
when given a formatter block or an appender option, such as `level:`, `formatter:`, or `filter:`,
which v5.3 ignored with a deprecation warning, since the instance was created with its own. Give
them to `new` instead. The options of `add_appender` itself, `async:`, `batch:`, and the queue
options, still apply to an instance, and an option given as `nil` sets nothing, so it is not
refused:

~~~ruby
# Before:
SemanticLogger.add_appender(appender: MyAppender.new, level: :warn)

# After:
SemanticLogger.add_appender(appender: MyAppender.new(level: :warn))
~~~

#### More than one destination raises `ArgumentError`

`add_appender` adds one destination. Given more than one of `file_name:`, `io:`, `logger:`,
`appender:`, and `metric:`, it now raises `ArgumentError`, which v5.3 reported as a deprecation
warning while it added only the first. Call `add_appender` once for each destination. A destination
given as `nil` is still not one. `appender: :wrapper`, which only worked with `logger:`, now raises
too: leave it out, since `logger:` already adds the wrapper.

#### Loki writes `pid` and `thread` as structured metadata

The `:loki` appender, and its formatter, now write the process id and the thread name as structured
metadata by default, as Loki advises and as v5.3 warned, rather than as the stream labels `pid` and
`thread`, which added a stream for every process restart and every thread. A query then filters on
them after the stream selector, as in `{application="shop"} | thread="worker-1"`.

Structured metadata needs a Loki with schema v13 and `allow_structured_metadata`, which is on by
default since Loki 3.0. Any other Loki rejects every entry, so for one that does not accept it, keep
them as labels:

~~~ruby
SemanticLogger.add_appender(appender: :loki, url: "https://logs-prod-001.grafana.net",
                            formatter: {loki: {structured_metadata: []}})
~~~

A `structured_metadata: [:pid, :thread]` added to silence the v5.3 warning can stay, or be removed.
See [pid and thread as structured metadata](appenders.html#pid-and-thread-as-structured-metadata).

#### `semantic_logger_events` takes the class as `klass:`

The Minitest helper `semantic_logger_events` takes the class whose events to capture only as the
keyword `klass:`, as deprecated in v5.4. Passing it positionally raises `ArgumentError`:

~~~ruby
# Before:
messages = semantic_logger_events(ApiClient) { ApiClient.new.call }

# After:
messages = semantic_logger_events(klass: ApiClient) { ApiClient.new.call }
~~~

The RSpec helper `capture_semantic_logger_events(ApiClient)` is unchanged.

#### `metric: :splunk_observability`

SignalFx is now Splunk Observability Cloud, so its metric appender can also be added as
`metric: :splunk_observability`. `metric: :signalfx` adds the same appender, and keeps working. See
[Splunk Observability Cloud (SignalFx)](metrics.html#signalfx).

#### The TCP appenders no longer use `net_tcp_client`

The `:tcp` appender, and the `:syslog` appender over TCP, connect with a class of their own,
`SemanticLogger::Appender::TcpConnection`, instead of `Net::TCPClient` from the `net_tcp_client` gem,
which you can remove from your Gemfile unless your application uses it itself. They take only
`server:`, `servers:`, `policy:` (`:ordered` or `:random`), `connect_timeout:`, `write_timeout:`,
`keepalive:`, and `ssl:`, plus `connect_retry_count: 0`, `retry_count: 0`, and `buffered: false`, which
are what they do, and raise `ArgumentError` for any other option, as v5.4 warned. In the `tcp_client:`
of `:syslog`, `server:` and `servers:` raise `ArgumentError` too: give the server in its `url:`.

What changes:

* **Retries.** It connects to each server once, rather than up to 10 times, and writes an entry once,
  rather than up to 3 times. When it cannot connect, it writes the entry again after the appender's
  back-off, without counting it as failed, so the worker thread no longer waits on retries during an
  outage. A write to a connection that the server reset or closed before any of it was sent, such as
  one that was idle, is written once more at once, on a new connection; a write that otherwise fails
  before any of it was sent, such as by timing out, is written again after the back-off instead.
* **Timeouts.** A negative `connect_timeout:`, `write_timeout:`, or `handshake_timeout:`, such as `-1`,
  still waits as long as it takes, and an option given as `nil` takes its default. `connect_timeout:`
  also bounds the look-up of a host name, which `Net::TCPClient` left unbounded.
* **Starting while the server is down.** When it cannot connect as it is added, or reopened, it
  reports that to the internal logger rather than raising, so the application still starts. It
  keeps the connection it has, if any; with none, as when it is added, the next write connects.
* **IPv6.** A host name is connected to at any of its addresses, IPv4 or IPv6, and an IPv6 address
  can be given in brackets, as in `"[::1]:514"`.
* **Errors.** A connection that fails raises
  `SemanticLogger::Appender::TcpConnection::ConnectError`, and a write that fails raises
  `TcpConnection::WriteError`, both a `SocketError`, rather than the errors of `Net::TCPClient`.
* **Readers.** `Tcp#tcp_client` and `Syslog#remote_syslog` return the `TcpConnection`.

#### Rails Semantic Logger

A `rails_semantic_logger` release for v6 will send `sidekiq.queue.latency` with
`logger.time("sidekiq.queue.latency", duration: latency_ms)`, a histogram of durations. Until then,
`rails_semantic_logger` 5.x sends it as the `metric_amount` of a log entry, which v6 records as a
counter of milliseconds, adding up the latencies of the interval.

`rails_semantic_logger` 5.x adds `formatter: :color` to the appenders declared with `add_server` and
`add_console`, which v6 refuses with an appender instance (see
[Options given with an appender instance raise `ArgumentError`](#options-given-with-an-appender-instance-raise-argumenterror))
and with a metric appender (see
[Options that now raise `ArgumentError`](#options-that-now-raise-argumenterror)). Until its v6
release, give such an appender `formatter: nil`, which sets nothing, so that it is not refused:

~~~ruby
config.rails_semantic_logger.appenders do |appenders|
  appenders.add_server(appender: MyAppender.new, formatter: nil)
  appenders.add_server(metric: :statsd, formatter: nil)
end
~~~

### Upgrading to Semantic Logger v5.3

#### OpenTelemetry log records

The `:open_telemetry` appender now sends the message as the body of each log record, as its
documentation described, instead of a map of the whole log entry. This matters if you query, alert
on, or build dashboards from the body of these records.

~~~
# Before:
body:       {"host" => "web-1", "application" => "my_app", "environment" => "production",
             "pid" => 12345, "thread" => "puma srv tp 001", "named_tags" => {request_id: "abc"},
             "name" => "UserService", "message" => "Created user"}
attributes: {"user_id" => 42}

# After:
body:       "Created user"
attributes: {"request_id" => "abc", "user_id" => 42, "semantic_logger.name" => "UserService",
             "thread.name" => "puma srv tp 001", "process.pid" => 12345}
~~~

* The payload attributes keep their names. An Array that mixes types, such as `[1, "two"]`, is now
  sent as Strings, `["1", "two"]`, since OpenTelemetry does not accept it otherwise.
* Each named tag is an attribute of its own, such as `request_id`, instead of `body.named_tags`. A
  payload key takes precedence over a named tag of the same name.
* The other fields of the entry are attributes too. A logged exception uses the OpenTelemetry
  semantic conventions, `exception.type`, `exception.message`, and `exception.stacktrace`, so that
  backends recognize it, and so do `code.file.path`, `code.line.number`, `thread.name`, and
  `process.pid`. The logger name, tags, duration, and metric are `semantic_logger.name`,
  `semantic_logger.tags`, `semantic_logger.duration_ms`, `semantic_logger.metric`, and
  `semantic_logger.metric_amount`, and each of a metric's dimensions is a
  `semantic_logger.dimensions.<key>` attribute. A named tag or payload key with one of these names, or
  starting with `semantic_logger.dimensions.`, is prefixed with its source, as in
  `payload.exception.type`.
* The host, application, and environment are no longer sent. Set them in the OpenTelemetry resource
  instead, which is sent once per export, with `OTEL_SERVICE_NAME=my_app` and
  `OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=production,host.name=web-1`.
* An entry without a message, such as `logger.error(exception)`, has no body.
* A named tag whose value is a Symbol, Time, or other object was sent as an empty value. It is now
  sent as its `#to_s`, or as JSON for a Hash, Array, `Struct`, or `Set`.
* `code.file.path` and `code.line.number` are where the entry was logged, and are left out when the
  entry has no call site (see `call_site_level`) and did not capture a backtrace. With a call site,
  `code.function.name` names the method. The old body's `file` and `line` fell back to where a logged
  exception was raised, which is now in `exception.stacktrace`.

A custom formatter given to this appender with `formatter:` must now return the keyword arguments for
the OpenTelemetry `Logger#on_emit` (`severity_text:`, `severity_number:`, `timestamp:`, `body:`, and
`attributes:`), as `SemanticLogger::Formatters::OpenTelemetry` does, instead of a Hash shaped like the
`:raw` formatter's.

The appender no longer sends metric-only entries, such as `logger.info(metric: "users/signup")`,
which have a metric but no message and no exception. It sent each one as a log record with no body,
its metric in the attributes, never as an OpenTelemetry metric. Metric-only entries are meant for the
[metric subscribers](metrics.html#metric-appenders), and most log appenders leave them out.
To keep sending them as log records, add the appender with `metrics: true`:

~~~ruby
SemanticLogger.add_appender(appender: :open_telemetry, metrics: true)
~~~

#### Choose `metrics:` for the `:kafka`, `:rabbitmq`, and `:udp` appenders

Unlike the other log appenders, `:kafka`, `:rabbitmq`, and `:udp` send metric-only entries by
default: entries such as `logger.info(metric: "users/signup")`, which have a metric but no message and
no exception, and are meant for the [metric subscribers](metrics.html#metric-appenders). v6
leaves them out by default, as the other log appenders do. Until then, adding one of these appenders
without `metrics:` still sends them, and reports a
[deprecation warning](#seeing-deprecation-warnings). Pass `metrics:` to choose:

~~~ruby
# Keep sending metric-only entries:
SemanticLogger.add_appender(appender: :kafka, seed_brokers: ["kafka1:9092"], metrics: true)

# Leave them out, as v6 does by default:
SemanticLogger.add_appender(appender: :kafka, seed_brokers: ["kafka1:9092"], metrics: false)
~~~

#### Negative metric amounts

A metric counts upward. In v6, a counter drops a negative `metric_amount`, and reports it once on
Semantic Logger's internal logger, rather than subtracting it. Until then, a log call or a
`measure_*` call with a `metric:` and a negative `metric_amount` is still logged and sent as before,
and reports a [deprecation warning](#seeing-deprecation-warnings) that names the line of the call.
It is reported
once per process, for the first negative amount only, so that a loop does not repeat it; once that
call is changed, the next one, if any, is reported. A `metric_amount` of zero is not negative, and
one without a `metric:`, which no metric subscriber receives, is not reported.

~~~ruby
# Deprecated:
logger.info(message: "Item removed", metric: "cart/items", metric_amount: -1)

# Count what goes down as a metric of its own:
logger.info(message: "Item removed", metric: "cart/items_removed")
~~~

To record a value that goes up and down, such as the number of items in a cart, a `gauge` is planned
for the metrics API of v6. (It is not in v6.0; see
[Negative metric amounts are dropped](#negative-metric-amounts-are-dropped).)

#### Choose where Loki writes `pid` and `thread`

The `:loki` formatter writes the process id and the thread name as the stream labels `pid` and
`thread`, so every process restart, and every thread, adds a Loki stream. Its new
`structured_metadata:` option writes either or both as structured metadata instead, as Loki advises,
and v6 writes both there by default. Until then, adding the `:loki` appender, or building its
formatter, without `structured_metadata:` still writes them as labels, and reports a
[deprecation warning](#seeing-deprecation-warnings). Pass it to choose:

~~~ruby
# Write them as structured metadata, as v6 does by default:
SemanticLogger.add_appender(appender: :loki, url: "https://logs-prod-001.grafana.net",
                            formatter: {loki: {structured_metadata: [:pid, :thread]}})

# Keep them as labels:
SemanticLogger.add_appender(appender: :loki, url: "https://logs-prod-001.grafana.net",
                            formatter: {loki: {structured_metadata: []}})
~~~

Structured metadata needs a Loki with schema v13 and `allow_structured_metadata`, which is on by
default since Loki 3.0. Any other Loki rejects every entry once `pid` is structured metadata, so
keep them as labels until your Loki accepts it.

As structured metadata, a query filters on them after the stream selector, a payload key named `pid`
or `thread` is written as `payload_pid` or `payload_thread`, and a named tag or context key of that
name as the label `pid_2` or `thread_2`:

```
# Labels:
{application="shop", thread="worker-1"}
# Structured metadata:
{application="shop"} | thread="worker-1"
```

See [pid and thread as structured metadata](appenders.html#pid-and-thread-as-structured-metadata).

#### Set the options of an appender instance on the instance

`add_appender` adds an appender or metric subscriber that is already created, given as `appender:` or
`metric:`, as it is, since it was created with its own options. A formatter block, or the options of
an appender, such as `level:`, `formatter:`, or `filter:`, given with it were ignored without a word.
They still are, but `add_appender` now reports a [deprecation warning](#seeing-deprecation-warnings)
that names them, and v6 raises `ArgumentError` for them. Set them on the instance itself, such as
when creating a [custom appender](config.html#custom-appenders):

~~~ruby
# Before, level: and formatter: were ignored:
appender = SimpleAppender.new(url: "https://logs.example.com")
SemanticLogger.add_appender(appender: appender, level: :warn, formatter: :json)

# After:
appender = SimpleAppender.new(url: "https://logs.example.com", level: :warn, formatter: :json)
SemanticLogger.add_appender(appender: appender)
~~~

The options of `add_appender` itself, such as `async:`, `batch:`, and `max_queue_size:`, still apply
to an instance. An option given as `nil`, such as `level: nil`, sets nothing, so it is not reported.

#### Give `add_appender` one destination

`add_appender` adds one destination, given as `file_name:`, `io:`, `logger:`, `appender:`, or
`metric:`. Given more than one of them, it added only the first, in that order, and ignored the
others without a word, so that `add_appender(file_name: "log/app.log", io: $stdout)` wrote to the
file, and nothing to `$stdout`. It still does, but now reports a
[deprecation warning](#seeing-deprecation-warnings) that names the destination it uses and those
it ignores, and v6 raises `ArgumentError` for them. Call `add_appender` once for each destination:

~~~ruby
# Before, $stdout was ignored:
SemanticLogger.add_appender(file_name: "log/app.log", io: $stdout)

# After:
SemanticLogger.add_appender(file_name: "log/app.log")
SemanticLogger.add_appender(io: $stdout)
~~~

An option that only the ignored destination accepts, such as the `url:` of `appender: :http`, went
to the one that was added, which raised `ArgumentError: unknown keyword`. While
[deprecation warnings are shown](#seeing-deprecation-warnings), the warning now comes before it,
naming the destination that was ignored.

`appender: :wrapper` only worked with `logger:`, which `add_appender` took as the destination
instead, so it now reports the same warning. Leave out `appender: :wrapper`:
`add_appender(logger: my_logger)` adds the same appender.

A destination given as `nil`, such as `file_name: options[:log_file]` when no log file is set, is not
one, so it is not reported.

#### Batch an appender with a formatter that can format a batch

`add_appender` now raises `ArgumentError` when it would batch an appender whose formatter cannot
format a batch, such as `formatter: :default` or a Proc given to `:http`, `:loki`, or
`metric: :signalfx` with `batch: true`, or a formatter block, which v5.3 now uses (see
[Other behaviour changes](#other-behaviour-changes)). Before, it added the appender, but every batch
failed on the appender's worker thread, which backed off and tried again, so nothing was ever
written, and once its queue was full, logging blocked, unless it was added with
`non_blocking: true`. Add the appender without
`batch: true`, or give it a formatter that implements `#batch(logs, logger)`, such as the one it
uses by default:

~~~ruby
# Before, nothing was ever sent:
SemanticLogger.add_appender(appender: :http, url: "https://logs.example.com", batch: true,
                            formatter: ->(log, _logger) { log.message })

# After, one request for each entry:
SemanticLogger.add_appender(appender: :http, url: "https://logs.example.com",
                            formatter: ->(log, _logger) { log.message })

# Or one request for each batch, formatted by the default :json formatter:
SemanticLogger.add_appender(appender: :http, url: "https://logs.example.com", batch: true)
~~~

`:splunk_http` with `batch: true` is not refused: it now sends each batch as the HTTP Event
Collector's event objects, stacked one after the other. Before, every batch failed. See
[Splunk HTTP](appenders.html#splunk-http).

A custom appender whose `#batch` formats each entry with `format_log` is batched with any formatter,
as before, including a subclass of `SemanticLogger::Appender::Http` that replaces its `#batch`. A
custom appender that cannot be batched in some configuration, such as one whose `#batch` formats the
whole batch with `format_batch`, can now say why from `#batch_refusal`, so that `add_appender`
raises instead. So can a subclass of `SemanticLogger::Appender::Http` whose `#batch` calls `super`,
which is not refused on its own. See [Custom appenders](config.html#custom-appenders).

#### Batch Elasticsearch with the `:elasticsearch` appender

`add_appender(appender: :elasticsearch_http, batch: true)` now raises `ArgumentError`. Batching it
never wrote anything: it posted each batch as a JSON array to the url's own path, such as `/`, which
Elasticsearch rejects, since it indexes a batch of entries only through its bulk API. Use the
`:elasticsearch` appender, which sends its entries in bulk requests, a batch at a time by default,
or add `:elasticsearch_http` without `batch: true`, to send each entry in its own request:

~~~ruby
# Before, nothing was ever indexed:
SemanticLogger.add_appender(appender: :elasticsearch_http, url: "http://localhost:9200", batch: true)

# After, in batches, through the bulk API (requires the elasticsearch gem):
SemanticLogger.add_appender(appender: :elasticsearch, url: "http://localhost:9200")

# Or one request for each entry:
SemanticLogger.add_appender(appender: :elasticsearch_http, url: "http://localhost:9200")
~~~

#### Loki stack traces

The `:loki` formatter now writes the `stack_trace` of a logged exception one frame per line, followed
by the backtrace of each exception that caused it, as the text formatters do. It wrote an inspected
Ruby Array and left out the causes. Update any query or alert that matches the old form:

~~~
# Before:
["app/models/order.rb:12:in 'Order#ship'", "app/controllers/orders_controller.rb:7:in 'OrdersController#create'"]

# After:
app/models/order.rb:12:in 'Order#ship'
app/controllers/orders_controller.rb:7:in 'OrdersController#create'
Cause: ArgumentError: invalid quantity
app/models/line_item.rb:3:in 'LineItem#save'
~~~

#### Custom formatters with a `backtrace_cleaner` of their own

Formatters now accept a `backtrace_cleaner` option (see
[Cleaning backtraces](config.html#cleaning-backtraces)), which the constructor of
`SemanticLogger::Formatters::Base` sets. A formatter of your own that keeps its own cleaner in
`@backtrace_cleaner`, and assigns it before calling `super`, has it replaced, by `true` in a
formatter built on the text or JSON formatters.

If your formatter cleans backtraces itself, rename its variable. Otherwise pass the cleaner to
`super` as the option, and the formatter it is built on cleans the backtraces it writes with it:

~~~ruby
class MyJson < SemanticLogger::Formatters::Json
  def initialize(**args)
    super(backtrace_cleaner: Rails.backtrace_cleaner, **args)
  end
end
~~~

#### `logger_measure_method` has been removed

`logger_measure_method`, an experiment that `SemanticLogger::Loggable` added to each class, has been
removed. A class that still calls it raises `NoMethodError` when it is loaded. To keep logging how
long a method takes, wrap its body in a `measure_*` block, and pass `metric:` to keep the metric it
logged:

~~~ruby
def run
  logger.measure_info("#run", metric: "MyClass/run") do
    # ...
  end
end
~~~

To trace the method instead, use OpenTelemetry's `tracer.in_span`, or the method tracer of an APM
agent.

#### Rails: cleaned backtraces, redaction, and call sites by default

If you use [rails_semantic_logger](rails.html), its v5.3 release requires Semantic Logger v5.3 and
turns on three of its new features by default: exception backtraces are cleaned with
`Rails.backtrace_cleaner`, the keys in `config.filter_parameters` are redacted from every log entry,
and in development each entry records its call site. Each changes the log output and can be turned
off. See [Upgrading to v5.3](rails.html#upgrading-to-v53) for details.

#### Other behaviour changes

* The `:loki` formatter now writes a payload key named like one of its own structured metadata
  fields (`metric`, `metric_value`, `dimensions`, `duration`, `duration_human`, `exception_name`,
  `exception_message`, and `stack_trace`), or that Loki stores under one of those names, such as
  `metric.value`, with a `payload_` prefix, also in an entry without that field, and under the name
  Loki stores it as, such as `payload_metric_value`. Before, Loki kept either the payload's value or
  the formatter's. Update any query or alert on such a payload key:

  ```
  # Before:
  {application="shop"} | duration="PT5S"
  # After:
  {application="shop"} | payload_duration="PT5S"
  ```
* The `:loki` formatter no longer lets a named tag, or a value that an `on_log` subscriber adds to
  the context, replace a label of the same name. Its own labels (`pid`, `application`,
  `environment`, `host`, `level`, `thread`, and `tags`) keep their values, a named tag keeps its
  value over a context key, and the later of the two is written with a number added, as in
  `host_2`, unless both have the same value. Before, the later value replaced the earlier one. Update
  any query or alert that selects such a named tag or context value by that name:

  ```
  # Before, with the named tag host: "db-1":
  {application="shop", host="db-1"}
  # After:
  {application="shop", host_2="db-1"}
  ```

  A subclass of `SemanticLogger::Formatters::Loki` that reads, replaces, or deletes a label in
  `stream[:stream]` needs to use a String key, such as `stream[:stream]["host"]`. The label names
  are now Strings rather than Symbols, so that a named tag or context key, whether a Symbol or a
  String, is found among them by name. A label that the subclass writes under a Symbol, as v5.2
  did, is written under its name as a String, and with a number added when a label written before
  it has that name, as a named tag is: `stream[:stream][:level] = "INFO"` after `super` adds
  `level_2="INFO"` rather than replacing `level`.

  A subclass that overrides both `#build_stream` and `#call` (or `#batch`), calling `super` in
  neither, leaves out each named tag and context value whose name another label has, or that Loki
  does not accept, such as `request-id`. The formatter writes those labels last, once the labels
  that keep their names are written: from its own `#build_stream`, or, for a subclass whose
  `#build_stream` does not call `super`, from its own `#call` and `#batch`. Such a subclass calls
  neither. To keep them, call `super` from the subclass's `#build_stream` and add or change its own
  labels in the stream it returns, or remove its `#call` and `#batch` when they repeat the
  formatter's own, as a copy of v5.2's does.
* The `:loki` formatter now writes a label past Loki's default limits, the 16th and later label of a
  stream, or one whose name is longer than 1024 bytes or whose value is longer than 2048 bytes, to
  the structured metadata instead, since Loki rejected the whole push for it. If your Loki raises
  these limits in its `limits_config`, set the formatter's options of the same names to match, or
  those labels can no longer be selected as labels:

  ```ruby
  SemanticLogger.add_appender(
    appender:  :loki,
    url:       "https://logs-prod-001.grafana.net",
    formatter: {loki: {structured_metadata: [:pid, :thread], max_label_names_per_series: 30}}
  )
  ```

  See [Loki's label limits](appenders.html#lokis-label-limits).
* The `#logger` of an appender added with `logger:`, such as the one `add_appender(logger: ...)`
  returns, is now its internal logger, the one it reports its own problems to, as for every other
  appender, and `#logger=` replaces that internal logger. Before, they returned and replaced the
  logger the appender writes to, which is now `#wrapped_logger` (the appender returned by
  `add_appender(logger: ..., async: true)` also answers it): `appender.logger = other` sent the
  entries to `other`, and `appender.logger.level = ::Logger::DEBUG` changed the level of the logger
  written to. To write to another logger, add an appender for it with
  `SemanticLogger.add_appender(logger: other)`, and remove the old one with
  `SemanticLogger.remove_appender(appender)`. The `:open_telemetry` appender's `#logger` and
  `#logger=` likewise no longer return or replace the OpenTelemetry logger.

  A subclass of `SemanticLogger::Appender::Wrapper` that writes through `logger` or `@logger` needs
  to use `wrapped_logger` instead. `logger` is now the internal logger, which by default writes only
  warnings and errors, to standard error, so the subclass's entries would be left out, and `@logger`
  is not set until `logger` is first called.
* The `:statsd` and `:new_relic` metric subscribers now record a metric that has `dimensions` under
  its name alone, leaving out the dimensions, which their clients do not accept. Before, they left
  such a metric out, so a counter or timer logged with dimensions can now show higher counts there.
  To leave them out again, add either subscriber with a filter:

  ~~~ruby
  SemanticLogger.add_appender(metric: :statsd, filter: ->(log) { !log.dimensions? })
  SemanticLogger.add_appender(metric: :new_relic, filter: ->(log) { !log.dimensions? })
  ~~~

  In v6 a metric appender takes no `filter:`; see
  [Options that now raise `ArgumentError`](#options-that-now-raise-argumenterror).
* A `measure_*` call now keeps its `dimensions:` option, which it used to drop. So the `:signalfx`
  metric subscriber sends a metric measured with dimensions as it sends any metric with dimensions:
  under its own name, such as `supplier.add_user` for `metric: "supplier/add_user"`, with those
  dimensions, and without a count. Before, it sent it as `Application.average` and
  `Application.counter`, with `class` and `action` dimensions taken from the metric name. It also
  no longer adds the named tags listed in the subscriber's own `dimensions:` option, which it only
  adds to a metric without dimensions, so put any of those values the metric needs in its
  `dimensions:`, such as `dimensions: {supplier: "acme", region: "eu-west"}`. A filter on
  `log.dimensions?`, as above, now applies to it too.

  Empty dimensions, such as `dimensions: {}` or `{supplier: nil}.compact`, and dimensions whose
  values are all blank (`nil`, or text that is empty or only whitespace), such as `{supplier: nil}`
  or `{state: ""}`, now count as none for `:signalfx`, on a log call too: the metric is sent as it
  would be without them, so a duration is sent as `Application.average` and `Application.counter`,
  and a count as `Application.counter`, each with the `class` and `action` dimensions taken from the
  metric name and the named tags listed in the subscriber's `dimensions:` option. Before, either was
  sent under its own name, without those dimensions, and a duration without a count. A value of only
  whitespace, which was sent before, is now also left out of dimensions that have other values, and
  of the named tags it forwards. `log.dimensions?`, and so a filter on it, as above, still counts
  dimensions whose values are all blank, such as `{state: ""}`, as dimensions; only empty ones, such
  as `{}`, count as none.

  In v6, `:signalfx` takes no `dimensions:` option, nor a filter, and sends a dotted name without
  dimensions under its own name; see [SignalFx metric names](#signalfx-metric-names).
* A `tagged` block now restores the tags and named tags that it found when it exits, instead of
  popping the ones it pushed, as `silence` and `with_level` blocks already did. This only changes code
  that pushes or pops tags with `push_tags` and `pop_tags`, or `push_named_tags` and
  `pop_named_tags`, across the edge of a block:
  * Tags pushed inside a block, and not popped, are removed when the block exits. Before, the block
    popped them in place of its own tags, which then stayed on the thread.
  * Tags pushed before a block, and popped inside it, come back when the block exits.

  Push and pop tags in matching pairs, or use the block form.
* `log_exception: :partial`, the default for `measure_*` blocks, now also adds the class of each
  exception that caused the logged one to the message, and its message when the text does not
  already hold it, as `log_exception: :full` already wrote them:

  ```
  # Before:
  Saving order -- Exception: RuntimeError: Could not save
  # After:
  Saving order -- Exception: RuntimeError: Could not save -- Cause: IOError: disk full
  ```

  Alerts, searches, or tests that match the whole message of such an entry need updating.
* An exception whose class overrides `self.name` or `self.to_s` is now named by the constant the
  class was assigned to, as Ruby names it in `Exception#inspect`, wherever Semantic Logger writes the
  class. Before, what `self.name` returned was written as `name` in `:raw`, and so in `:json`,
  `:logfmt`, `:fluentd`, `:ecs`, `:syslog_cee`, and `:new_relic_logs`, as `exception_name` in
  `:loki`, and in each `Cause:` line of a backtrace, while the text formatters (`:default`,
  `:color`, `:one_line`, `:pattern`, and `:syslog`) and `log_exception: :partial` wrote what
  `self.to_s` returned. A class without a constant is named as Ruby writes the class, such as
  `#<Class:0x000...>`, even when it gives itself a name. Update any search, alert, or dashboard that
  selects such an exception by the name its class gave itself:

  ```ruby
  class DeclinedError < StandardError
    def self.name = "Payments::Declined"
    def self.to_s = name
  end
  # Before, in :json:    "exception":{"name":"Payments::Declined",...}
  #         in :default: -- Exception: Payments::Declined: Card declined
  # After,  in :json:    "exception":{"name":"DeclinedError",...}
  #         in :default: -- Exception: DeclinedError: Card declined
  ```
* `:default`, `:color`, `:pattern`, and `:syslog` with `escape_control_chars: false` now always
  write UTF-8, as the JSON based formatters, `:one_line`, and `:syslog` with its default
  `escape_control_chars: true` already did. Text in another encoding, such as ISO-8859-1, used to be
  written in that encoding, and an entry that mixed it with UTF-8 text was lost; it is now converted
  to UTF-8, and so are a pattern or time format in another encoding. Binary text is read as the
  UTF-8 it usually holds, without its bytes that are not valid UTF-8, instead of being written
  byte for byte. An application whose log files, or the tools that read them, expect another
  encoding needs to expect UTF-8 instead.
* `escape_control_chars: true`, which the `:syslog` formatter and the syslog appender use by
  default, now also escapes the Unicode characters that control how text is shown, as `\uXXXX`: the
  C1 control characters (U+0080 to U+009F), the line and paragraph separators (U+2028, U+2029), and
  the bidirectional controls (U+202A to U+202E, U+2066 to U+2069). Searches or parsers that match
  logged text holding them, such as localized text wrapped in bidirectional isolates, need to match
  the escaped form instead.
* The `:new_relic` metric subscriber now adds `Custom/` to a metric name that starts with `Custom`
  but not with `Custom/`, recording `Customers/signup` as `Custom/Customers/signup`, and
  `CustomerSignup` as `Custom/CustomerSignup`. Before, it recorded such a name as it was, which New
  Relic does not chart as a custom metric. With another `prefix:`, the same applies to a name that
  starts with that prefix but not with it and a `/`. A prefix given with a trailing `/` no longer
  doubles it: with `prefix: "Custom/"`, `Orders/placed` is recorded as `Custom/Orders/placed`, not
  `Custom//Orders/placed`. Dashboards, alerts, and NRQL queries on an old name stop receiving data,
  so update them to the new one.
* `SemanticLogger.reopen` within the same process, such as `reopen(force: true)` after a log
  rotation, keeps the log entries that are still queued, and the thread that writes them, rather
  than replacing both and losing the entries. So it no longer stops a thread that is waiting
  between retries after an appender failed, or one that is stuck writing; it only starts the thread
  again once it has stopped. After a fork, the child still starts with an empty queue.
* The `:http`, `:elasticsearch_http`, `:splunk_http`, and `:loki` appenders, and the `:signalfx`
  metric subscriber, now raise an error from `#log` and `#batch` when the server answers with a status
  other than 2xx, instead of reporting it and carrying on. With `async: true` or `batch: true`, the
  entries the server did not accept are now counted as `failed` in `SemanticLogger.stats`, rather
  than `processed`. On a 408, 429, or 503, the worker thread now backs off (1 second, then 2, ...),
  then sends the same entry or batch again, up to 3 times, before it discards it and carries on with
  the next one. So does a request it could not send because it could not connect, which was
  discarded before, except that such a failure does not count towards the 3 times, since the server
  never answered. On any other 5xx, such as a 500, 502, or 504, or a redirect, it discards the entry
  or batch, then backs off before sending the next one. It stops for good after `async_max_retries`
  (default `100`) failures in a row. During an outage the entries logged meanwhile now wait on the
  queue while the worker thread backs off, rather than being sent, and discarded, one per back-off,
  so with a capped queue (the default) and without `non_blocking`, logging waits once the queue is
  full until the server is back or the thread gives up. Pass `async_max_retries: -1` to keep trying
  through a long outage. On a 400, 413, or 422, a batch is now
  split up and sent again in parts, to find the entries the server rejects, so a server that kept
  some entries of a request it rejected can store them twice. On any other 4xx, such as 401 or 404,
  which the server answers whatever the request holds, the whole batch is discarded at once. See
  [When the server does not accept a request](appenders.html#when-the-server-does-not-accept-a-request).

  While the worker thread backs off, the entries logged meanwhile wait on the appender's queue, as
  they already did while the server could not be reached. Once that queue, and then the main queue,
  are full, logging calls block until the server accepts requests again. Add an HTTP appender that
  uses `async: true` or `batch: true` with `non_blocking: true` as well, so that its entries are
  dropped once its queue is full instead; see
  [Drop messages instead of blocking](operations.html#drop-messages-instead-of-blocking).

  Without `async:` or `batch:`, each failure is still reported to the internal logger, now as
  `Failed to log to appender`, with the error and its backtrace. A subclass of
  `SemanticLogger::Appender::Http` that checks the result of `post` or `put` now gets a
  `SemanticLogger::Appender::Http::ResponseError` raised instead of `false`.
* A flush or close of an appender added with `async: true` or in batches no longer waits out the
  back-offs of its worker thread during an outage, which could keep the flush at exit waiting for
  minutes: 1 second for the first entry queued, 2 for the next, and so on. It ends the back-off
  under way, and until it has run, an entry or batch that the destination fails is discarded,
  counted as `failed`, rather than sent again after a back-off, and so are the entries queued after
  it, ahead of the flush or close, without being sent (see the next note). A custom appender can now
  say that a write that raised wrote nothing, from `#wrote_nothing?(exception)`, so that the worker
  thread writes it again after the back-off, up to 3 times once the destination answered it, and
  that the write never reached the destination, from `#not_sent?(exception)`, which is not counted;
  see
  [Custom appenders](config.html#custom-appenders). A subclass of `SemanticLogger::Appender::Http`
  whose `#log` or `#batch` sends more than one request inherits a `#wrote_nothing?` that answers
  `true` for a 503 or a refused connection from any of them, which sends the entries of the earlier
  requests a second time: override it to return `false` for a failure after the first request.
* During an outage of the destination of an appender added with `async: true` or in batches, a flush
  or close, including the flush at exit, now discards that appender's entries queued ahead of it once
  a write fails, counted as `failed` in `SemanticLogger.stats`, rather than send each one in turn.
  Before, it waited while each one failed, up to the `open_timeout` of an HTTP based appender
  whose server does not answer, so that a process with 10,000 entries queued could take hours to
  exit. At exit, each such appender is also told that the process is exiting before the flush, so
  that it stops backing off even while the thread that writes to every appender is held up handing
  it an entry. The entries queued after a flush, and every entry to a destination that takes them,
  are written as before. The entries discarded are reported to the internal logger, as for any entry
  that could not be written.
* During an outage of the destination of an appender added without `async: true`, and not in
  batches, such as a plain `:http`, `:splunk_http`, `:tcp`, or `:udp`, the process now exits within
  seconds too. Once a write to such an appender fails because of its destination while the process
  exits, it is given no more of the entries queued ahead of the flush at exit, or logged meanwhile,
  and the number it was not given is reported to the internal logger, as
  `Discarded ... log message(s) during the flush at exit, after the destination failed`. The flush
  at exit still flushes it, so that it delivers the entries it already accepted. Before, the
  flush at exit waited while each one failed in turn, up to the `read_timeout` or `open_timeout` of
  an HTTP based appender each. The other appenders still get every entry, and while the process
  runs, such an appender is still given every entry. See
  [Retry a failing appender](operations.html#retry-a-failing-appender).
* The `:elasticsearch` and `:opensearch` appenders now send again the entries of a bulk request that
  the server rejected with status 429, because its write queue was full, up to 3 times, after waiting
  0.2, 0.4, then 0.8 seconds. Before, they were reported and discarded straight away. That holds up
  the thread that writes the entries for waits of at most 1.4 seconds for a request, plus up to 3
  more bulk requests. It is the appender's own thread when it writes in batches, as it does by
  default, or with `async: true`. With `batch: false`, and without `async: true`, it is the thread
  that writes to every appender, or with `SemanticLogger.sync!`, the thread that logged, and every
  other thread that logs waits for it. The report of the entries still not indexed now comes after
  those waits. See [Elasticsearch](appenders.html#elasticsearch).
* `SemanticLogger.reopen` now only asks for the appenders to be reopened, each by the thread that
  writes its entries, before it writes the next one. With `SemanticLogger.sync!` on, that is still
  the calling thread for every appender without a thread of its own (added without `async: true` or
  batching). Before, it
  reopened them on the calling thread, often a signal trap after a log rotation, while the thread
  that writes the entries could be writing to them: the file appender could close its file under an
  entry being written, and the HTTP appenders could end a connection under a request, or, with some
  versions of the timeout gem, fail with `ThreadError` in a trap. So `reopen` now returns before the
  appenders have reopened; call `SemanticLogger.flush` after it to wait until they have, for example
  in a test. An entry still queued when `reopen` is called can now be written to the new file. The
  error from an appender that cannot be reopened is reported by that thread, rather than raised from
  the proxy of an appender added with `async: true` or in batches, which now reports it to the
  appender's own internal logger, as `Async: Failed to reopen the appender`.
* A block given to `add_appender` with an appender or metric subscriber named by a Symbol, such as
  `add_appender(appender: :http, url: ...) { |log| log.message }`, now formats its entries, taking
  precedence over `formatter:`, as it does for `io:`, `file_name:`, and `logger:`. v5.2 ignored it
  and used the appender's `formatter:` or its default formatter, so what such an appender sends
  changes. With `batch: true`, `:http`, `:loki`, and `metric: :signalfx` now raise `ArgumentError`
  for it (see [Batch an appender with a formatter that can format a batch](#batch-an-appender-with-a-formatter-that-can-format-a-batch)),
  where v5.2 sent batches formatted by the default formatter. Remove the block to keep the output
  of v5.2.
* Some appenders now check their settings as they are added, and raise there, rather than failing
  each entry later:
  * `add_appender(metric: :statsd, url: ...)` connects as it is added, so it raises when its `url:`
    is not `udp://` or its host cannot be resolved, where v5.2 added it and then failed every
    metric. Add it only where the Statsd host resolves.
  * `add_appender(appender: :udp, server: ...)` raises `ArgumentError` for a `server:` that is not
    `"host:port"`, such as one without a port. Write an IPv6 address in brackets, as
    `"[::1]:8088"`.
* `SemanticLogger::Processor.logger=` (and `SemanticLogger::SyncProcessor.logger=`) now raises
  `ArgumentError` when given a `SemanticLogger::Logger`, whose reports of a failing appender went
  back to that appender, failed again, and were reported again. Give it an appender, such as
  `SemanticLogger::Appender::IO.new($stderr)`, or a Ruby or Rails `Logger`, which it now accepts.
* `SemanticLogger.remove_appender` now waits, as `SemanticLogger.flush` does, until the messages
  already logged are written and the appenders flushed, before it closes the appender, so it can
  take as long as a flush. Called on the thread of an appender added with `async: true` or in
  batches, it returns `true` at once, and the appender is closed shortly after. See
  [Adding and removing appenders](config.html#adding-and-removing-appenders).
* The `:open_telemetry` and `:new_relic_logs` appenders now keep the trace context they capture
  with `Log#capture`, which formatters do not write, instead of in `log.context`. A custom formatter
  or appender that read `log.context[:open_telemetry]` or `log.context[:new_relic_metadata]` reads
  `log.captured(:open_telemetry)` or `log.captured(:new_relic_metadata)` instead, and an `on_log`
  subscriber that set either key with `log.set_context` sets it with `log.capture`.

### Upgrading to Semantic Logger v5.2

v5.2 sends the configured facility to remote syslog, deprecates the `:splunk` appender, stops
replacing Ruby's `Thread#name`, and fixes several security issues. None of the security fixes change
the public API, but a few change the output, which matters if you parse the logs or alert on them,
and the file appender's `permissions:` option can now make `add_appender` raise for a log file that
worked in v5.1.

#### Set the Sentry user and fingerprint with named tags

The `:sentry_ruby` appender takes the Sentry user (`user_id`, `username`, `user_email`, `ip_address`,
and `user`) and `fingerprint` from named tags or the payload. Taking them from the payload is
deprecated and will be **removed in v6**, since the payload often holds untrusted data, such as a
request body, which could then set the user an error is reported for. It emits a deprecation warning
the first time it happens. Until then, the named tags win over the payload, which no longer replaces
a user field they set, and only a String, Symbol, or Integer is taken from the payload for a user
field. Set them with named tags instead, which can now also hold the `fingerprint`:

~~~ruby
# Before:
logger.error("Payment failed", user_id: user.id, fingerprint: ["payment-failed"])

# After:
SemanticLogger.tagged(user_id: user.id, fingerprint: ["payment-failed"]) do
  logger.error("Payment failed")
end
~~~

#### Replace the `:splunk` appender with `:splunk_http`

The `:splunk` appender depends on the `splunk-sdk-ruby` gem, which was last released in 2015 and
does not verify the server's TLS certificate. It now emits a deprecation warning and will be
**removed in v6**. Send logs to the Splunk HTTP Event Collector instead:

~~~ruby
# Before:
SemanticLogger.add_appender(appender: :splunk, index: "main")

# After:
SemanticLogger.add_appender(
  appender: :splunk_http,
  url:      "https://splunk.example.com:8088/services/collector/event",
  token:    "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  index:    "main"
)
~~~

#### Remote syslog sends the configured facility

When logging to a remote syslog server over TCP or UDP, earlier versions sent the wrong facility.
The `facility:` option is documented as one of Ruby's `::Syslog::LOG_*` facility constants, but the
value was sent as if it were already the syslog protocol's facility number. Those constants are the
facility number shifted left by 3 bits, so the default `::Syslog::LOG_USER` (8) went out as facility
8, which is `uucp`, instead of facility 1, `user`. For example a `:info` message, at the default
`LOG_NOTICE` severity, was sent as `<69>` rather than `<13>`. Logging to a local syslog daemon was
not affected.

v5.2 sends the facility the constant names. If your syslog server filters or routes on facility,
for example an rsyslog rule for `uucp.*`, change it to the facility you configured: `user` unless
you set one.

The `facility:` option now only accepts the `::Syslog::LOG_*` facility constants, and raises
`ArgumentError` for other values when the appender is created. Previously a constant other than
`::Syslog::LOG_KERN`, `::Syslog::LOG_USER`, or `::Syslog::LOG_MAIL` raised `ArgumentError` while
logging. If you passed a bare facility number to get around that, switch to the constant. Check
this even if nothing raises: a bare 0, 8, or 16 is now read as `::Syslog::LOG_KERN`,
`::Syslog::LOG_USER`, or `::Syslog::LOG_MAIL`, so `16`, which used to send `local0`, now sends
`mail`:

~~~ruby
# Before (16 was sent as facility local0, and is now read as ::Syslog::LOG_MAIL):
SemanticLogger.add_appender(appender: :syslog, url: "udp://myloghost:514", facility: 16)

# After:
SemanticLogger.add_appender(appender: :syslog, url: "udp://myloghost:514", facility: ::Syslog::LOG_LOCAL0)
~~~

This applies to the `:syslog` and `:syslog_cee` formatters. An application that logs only to a remote
server, and so does not need the `syslog` gem, can use the same constants from
`SemanticLogger::Formatters::Syslog`, for example `SemanticLogger::Formatters::Syslog::LOG_LOCAL0`.

#### The file appender's `permissions:` refuses a log file it cannot secure

With `permissions:`, the file appender only writes to a regular file owned by the process, with a
single hard link, that the file name names directly rather than through a symbolic link.
`SemanticLogger.add_appender` now raises `IOError`, giving the reason, for any other log file,
which v5.1 wrote to, changing the permissions of whatever a link pointed at. So a configuration
that worked in v5.1 can now fail at boot, for example `permissions:` on a log file that is a
symbolic link to `/dev/stdout`, or on a log file that another user created. With `permissions:`,
a log file that cannot be opened also raises `IOError`, instead of the operating system's error,
such as `Errno::ENOENT`, which is its `cause`. A log file that fails the check, or to open, when it
is reopened later, on a rotation or after a fork, is reported to the internal logger and not
written to until it is fixed, instead of raising from the logging thread.

If you set `permissions:` on such a log file, either fix the file or remove `permissions:`. To log
to standard output, use `io: $stdout`:

~~~ruby
# Before, with log/production.log a symbolic link to /dev/stdout:
SemanticLogger.add_appender(file_name: "log/production.log", permissions: 0o640)

# After:
SemanticLogger.add_appender(io: $stdout)
~~~

#### Ruby's own `Thread#name` is no longer replaced

Earlier versions replaced `Thread#name` and `Thread#name=` with Semantic Logger's own versions,
which were written before Ruby had them and kept the name away from Ruby itself. v5.2 leaves Ruby's
own in place, so the name now also reaches the operating system, profilers, and `Thread#inspect`.
On MRI, log entries do not change: a thread that has no name is still logged with its object id.

Code anywhere in the application that calls `Thread#name` or `Thread#name=` now gets Ruby's
behaviour:

* `Thread#name` returns `nil` for a thread that has no name, where it returned the thread's object
  id as a String (on JRuby, its JVM thread name). The main thread has no name on MRI; JRuby names it
  `main`.
* `Thread#name=` is Ruby's built-in implementation again, with Ruby's standard behaviour, instead of
  Semantic Logger's version, which accepted any value and converted it with `to_s`. Ruby's version
  raises `TypeError` for a value that is not a String or `nil`, such as a Symbol or an Integer. It
  raises `ArgumentError` for a String that contains a NUL byte (`"\0"`), or whose encoding is not
  ASCII-compatible, such as UTF-16. Setting `nil` leaves the thread with no name, where it set the
  name to `""`.

~~~ruby
# Before:
Thread.current.name = worker_number
Thread.current.name.start_with?("worker")

# After:
Thread.current.name = "worker-#{worker_number}"
Thread.current.name&.start_with?("worker")
~~~

Tests that expect `thread_name: Thread.current.name` from the
[test helpers](testing.html) no longer work on a thread that has no name, such as the main thread
on MRI: `Thread.current.name` is now `nil`, while the log entry still holds the thread's object id.
The RSpec matchers `be_a_semantic_logger_event` and `log_semantic_logger_event` then fail. Worse,
`assert_semantic_logger_event` in Minitest takes `nil` to mean "do not check", so the test still
passes but no longer checks the thread name. Expect the object id when the thread has no name:

~~~ruby
# Before:
assert_semantic_logger_event(event, thread_name: Thread.current.name)

# After:
assert_semantic_logger_event(event, thread_name: Thread.current.name || Thread.current.object_id.to_s)
~~~

Semantic Logger's own threads are now named after their appender, such as `SL File`, with
`SL Appenders` for the main one, instead of `SemanticLogger::Appender::File` and
`SemanticLogger::Appenders`. Linux keeps only the first 15 bytes of a thread name, so the longer
names all looked the same in tools that list threads, such as `top -H`. The new names also appear
in the thread column of the messages Semantic Logger logs about its own problems, such as an
appender that cannot write.

On JRuby:

* A Ruby thread that has no name is logged with its object id, instead of its JVM thread name, such
  as `Ruby-0-Thread-1: app/worker.rb:12`. Name the thread to give it a readable name in the logs. A
  thread created by Java code, such as a servlet container's request thread, is still logged with
  its JVM thread name, which now also stays current when Java code renames the thread.
* Naming a Ruby thread sets its JVM thread name in JRuby's own format, such as
  `Ruby-0-Thread-2@My Worker: app/worker.rb:12`, instead of exactly `My Worker`. Update any JVM
  monitoring that matches thread names exactly.

#### Output changes

* `:logfmt`: spaces, control characters, invisible format characters (such as a zero width space),
  `=`, `"`, and Unicode line separators in keys are replaced with `_`, and invalid UTF-8 bytes are
  dropped. A tag such as `second breakfast` is now emitted as `second_breakfast=true`. A tag,
  named tag, or payload key named like one of the entry's own fields, which are the time key
  (`timestamp` by default), `level`, `name`, `message`, `duration`, `duration_ms`, `tag`, and the
  exception fields, is emitted with its source as a prefix, such as `payload.name="shrek"` or
  `tags.message=true`, instead of replacing the field, and so is a key that starts with `tags.`,
  `named_tags.`, or `payload.`. A logged exception's class and message are emitted as
  `exception_name` and `exception_message` (followed by `stack_trace` and `cause` as before),
  instead of replacing the entry's `name` and `message`, and the detail that
  `log_exception_details: true` adds as `exception_details`. Other keys that are the same once
  encoded, such as `:user` and `"user"`, are emitted once, with the value from the later source:
  the payload over named tags, and named tags over tags. A payload that is not a Hash is emitted
  as a single `payload` field. A nested value (a Hash, Array, `Struct`,
  `Data`, `Set`, or any other value whose JSON is an object or an array, such as the exception
  backtrace) is emitted as quoted JSON, `user="{\"id\":7}"`, instead of its `#inspect` text.
* `:syslog`: an entry with an exception stays on one line; the newlines between the exception and
  its backtrace are escaped as `\n`.
* `:default`, `:color`, `:pattern`, and `:syslog`: with `escape_control_chars`, the logger name,
  thread name, file name, payload, the messages of the exceptions that caused the logged exception,
  and the backtrace lines are escaped too. Invalid UTF-8 bytes are dropped instead of the entry failing to
  format. With escaping on, `:color` renders the payload plain and on one line, since Amazing
  Print's colors and line breaks cannot be told apart from control characters in the data.
* `:one_line`: line breaks are removed from every field (name, thread name, file name, tags, named
  tags, payload, message, and exception), carriage returns as well as newlines, and
  `escape_control_chars` is honoured.
* JSON based formatters: `Infinity` and `NaN` payload values are serialized as strings, and
  structures nested deeper than 32 levels are replaced with a placeholder such as
  `#<Hash nested too deeply>`, instead of the whole entry being dropped. A `Struct`, `Data`, or
  `OpenStruct` value is written as an object of its members, and a `Set` as an array, as Rails
  already does, instead of its `#inspect` text. An exception in the payload is written as its
  message, and any other object whose JSON fails because of invalid UTF-8 as its `#to_s`, with
  the invalid bytes dropped. The `:elasticsearch` and `:opensearch` appenders write their bulk lines the same way.
* JSON based formatters and `:one_line`: invalid UTF-8 bytes in the message are dropped, and a
  message in another encoding is converted to UTF-8, instead of the entry failing to format.
* `:loki`: a nested Hash, Array, `Struct`, or `Set` in the payload is written once as JSON, keeping
  the JSON types of its values, so `{number: 1}` is written as `{"number":1}` rather than
  `{"number":"1"}`, and `[1, 2, 3]` as `[1,2,3]`. A payload that is not a Hash is written as a
  single `payload` field.
* `:open_telemetry`: a `Struct`, `Set`, or other structure in the payload, or in an Array in it, is
  written as JSON instead of its `#inspect`. A payload that is not a Hash is submitted as a single
  `payload` attribute.
* Hashes logged as the payload, for example `logger.info("Webhook", params)`: a key that is also
  a log argument (`duration`, `metric_amount`, `backtrace`, `log_exception`, ...) is only used as
  that argument when its value is valid for it. Otherwise it stays in the payload, where it was
  previously consumed or made the call raise. A `nil` value is ignored. When an explicit
  `payload:` is also given, the other keys win over its values of the same name, a String key such
  as `"account_id"` having the same name as `:account_id`.
* Hashes returned from a logging block, for example `logger.info("Webhook") { {user: "bob"} }`, are
  checked the same way. A log argument from the block, such as `message`, `duration`, `exception`,
  or `backtrace`, is only used when the log entry does not have it yet, and is otherwise kept in the
  payload. A backtrace captured because the level is at or above `backtrace_level` counts, so the
  block's `backtrace` no longer replaces it. The block's keys no longer replace values the log call
  supplied under the same name, whether as a String or a Symbol, and win over the values of the
  block's own `payload` with the same name.
* The HTTP appender and the appenders built on it (`:elasticsearch_http`, `:splunk_http`, `:loki`,
  `:signalfx`): the url in the error logged for a rejected request shows only the scheme, host,
  and port, and `#inspect` shows only the object address and that url.
* The `:statsd` metrics appender sends a counter as a single `metric:amount|c` packet.

#### Other behaviour changes

* An async or batching appender discards a log message that it cannot format, instead of
  retrying it. Discarded messages are reported to the internal logger and counted in the new
  `failed` key of the appender's stats. Every error raised by a built-in appender's formatter
  counts, as does a message too large for a UDP datagram, a MongoDB document that BSON cannot
  serialize, and a message GELF cannot send. A custom appender can format through
  `format_log(log)` (or `format_batch(logs)`) instead of `formatter.call` to get the same
  treatment, or override `#message_error?` for errors its own client raises.
* The text formatters write a payload nested more than 32 levels deep as the JSON formatters
  write it, cut off with their placeholder, such as `"#<Hash nested too deeply>"`.
* A log message that overflows the stack while it is written is discarded, and the worker
  thread carries on in a new thread, instead of the worker stopping for good.
* `#inspect` on every appender shows only its class, object address, and what it says is safe to
  show, such as `url="https://es.example.com:9200"`, `queue_name="logs"`, or `group="/my/app"`,
  instead of its instance variables. A custom appender can show more by overriding
  `#inspect_details`. An appender added with `async: true` or `batch: true` shows as
  `#<SemanticLogger::Appender::Async:0x... batch=true appender=#<...>>`.
* `:cloudwatch_logs` sends the buffered messages in as many requests as the PutLogEvents limits
  need, oldest first, cuts short a message larger than 1 MB, and reports to the internal logger a
  request that fails, and the messages that AWS rejects as too new, too old, or expired. It formats each message when it is logged, writes invalid UTF-8 as valid
  UTF-8, and discards a message that its formatter cannot write, or writes as something other than
  a String with content, instead of failing the whole request.
* `:sentry_ruby` leaves the log entry's payload and named tags unchanged, so every appender after
  it, and your own Hash, keep the keys it reads. A user field, or `user` Hash, in the payload no
  longer replaces one from the named tags. A payload user field that is not a String, Symbol, or
  Integer, a `fingerprint` that is not an Array of Strings, Symbols, or numbers, and a payload that
  is not a Hash, are sent as data instead.

#### Stricter `logger_measure_method` arguments

`logger_measure_method` now raises `ArgumentError` for a method name that is not a valid Ruby
method name, a `min_duration` that is not a finite number, and an invalid `log_exception` or
level. Numeric Strings, such as `min_duration: "100"`, are still accepted.

### Upgrading to Semantic Logger v5.1

v5.1 deprecates several legacy appenders and one appender option, and changes when the file appender
opens its log file.

The deprecated appenders and option all still work in v5.1, but each now emits a Ruby deprecation
warning and will be **removed in v6**. The warnings use `category: :deprecated`, so they are silent
by default and appear when deprecation warnings are enabled (for example `ruby -W:deprecated`, or
Rails development mode). Switch away now to be ready for v6.

#### Replace the `:sentry` appender with `:sentry_ruby`

The `:sentry` appender depends on the end-of-life `sentry-raven` gem. Use the `:sentry_ruby`
appender, backed by the maintained `sentry-ruby` gem.

In your `Gemfile`:

~~~ruby
# Remove:
gem "sentry-raven"
# Add:
gem "sentry-ruby"
~~~

When adding the appender:

~~~ruby
# Before:
SemanticLogger.add_appender(appender: :sentry)

# After:
SemanticLogger.add_appender(appender: :sentry_ruby)
~~~

#### Replace the `:new_relic` appender with `:new_relic_logs`

The `:new_relic` appender reports `:error` and `:fatal` entries to New Relic as **error events** via
`newrelic_rpm`. It is superseded by `:new_relic_logs`, which forwards log entries to New Relic Logs:

~~~ruby
# Before:
SemanticLogger.add_appender(appender: :new_relic)

# After:
SemanticLogger.add_appender(appender: :new_relic_logs)
~~~

Note that the behaviour differs. `:new_relic` created New Relic *error events* (and defaulted to the
`:error` level), whereas `:new_relic_logs` forwards *log messages* to New Relic's log ingestion. Set
`level:` to match what you want forwarded, and update any New Relic dashboards or alerts that relied
on the old error events. Both appenders require the `newrelic_rpm` gem.

#### Remove the `type:` option from the Elasticsearch and OpenSearch appenders

Document `_type` has been unused since Elasticsearch 7, so the `type:` option (on `:elasticsearch`,
`:elasticsearch_http`, and `:opensearch`) is now ignored on all server versions: the bulk appenders
no longer send a `_type`, and the `:elasticsearch_http` appender posts to the typeless `_doc`
endpoint. Passing `type:` logs a deprecation warning. Remove it:

~~~ruby
# Before:
SemanticLogger.add_appender(appender: :elasticsearch, url: "http://localhost:9200", type: "log")

# After:
SemanticLogger.add_appender(appender: :elasticsearch, url: "http://localhost:9200")
~~~

#### The file appender opens its log file when it is created

The file appender now opens its log file at creation rather than on the first write, matching the
other appenders. A bad path or insufficient permissions therefore raises immediately from
`SemanticLogger.add_appender`, instead of surfacing later on the appender thread while log messages
are lost. This restores the pre-4.9 behavior.

As a result the log file is created as soon as the appender is added, even if nothing has been
logged yet, the same as the standard Ruby and Rails loggers. If you add appenders inside a `rescue`
or a conditional that assumed creation could never fail, review it: the failure now happens earlier
and in the calling thread.

#### Rails: log file failures are caught at boot

If you use [rails_semantic_logger](rails.html), the companion gem's v5.1 release pairs with the
eager open above: a log file that cannot be opened is now caught during boot and the app falls back
to standard error at the `:warn` level, rather than booting against a silently broken appender. v5.1
also drops support for Sidekiq v4, v5, and v6. See
[Upgrading to v5.1](rails.html#upgrading-to-v51) for details.

### Upgrading to Semantic Logger v5.0

#### Minimum Ruby version is now 3.2

Semantic Logger v5 requires Ruby 3.2 or later. Earlier Ruby versions are end-of-life and are no
longer supported or tested.

If you are on an older Ruby, upgrade Ruby before upgrading Semantic Logger, or stay on the v4.x
series.

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

#### Appenders are reopened automatically after fork

Previously, applications that fork (Puma, Unicorn, Spring, Resque, `Process.daemon`, etc.) had to
call `SemanticLogger.reopen` themselves in an after-fork hook, otherwise the child shared the
parent's file handles and background thread.

In v5 this happens automatically: a `Process._fork` / `Process.daemon` hook calls
`SemanticLogger.reopen` in the child process. The call is guarded to run once per process.

For most applications you can now **remove** the manual reopen hook, for example:

~~~ruby
# No longer needed in v5 — handled automatically:
before_fork { SemanticLogger.flush }
after_fork  { SemanticLogger.reopen }
~~~

If you have a reason to manage this yourself (for example you reopen at a very specific point in
your boot sequence), disable the automatic behaviour:

~~~ruby
SemanticLogger.reopen_on_fork = false
~~~

#### Recommended: enable logger caching

By default `SemanticLogger[SomeClass]` returns a **new** `Logger` instance on every call. This means
that if one part of the code obtains a logger and later changes its `level` (or filter), other
holders of "the same" logger do not see the change, because they hold different instances.

v5 adds opt-in caching so that a `Class` or `Module` maps to a single shared `Logger` instance:

~~~ruby
SemanticLogger.cache_loggers = true
~~~

With caching enabled:

- `SemanticLogger[MyClass]` and the `Loggable` mixin's `MyClass.logger` return the **same** instance.
- Changing that logger's level or filter is visible to every holder.
- Strings (`SemanticLogger["Name"]`) always get a fresh instance, and anonymous classes (no `name`)
  are never cached.

Enabling caching is recommended for most applications. It is opt-in (default `false`) to preserve
existing behaviour for code that relied on getting an independent logger per call. If you need to
discard cached loggers (for example in tests, or after redefining a class), call
`SemanticLogger.clear_logger_cache`.

#### Control characters are escaped in Syslog output

To prevent log-injection via embedded control characters (newlines, escape sequences, etc.), the
Syslog formatter now escapes control characters in records by default. If you relied on raw control
characters reaching syslog, this output now differs. The text formatters (default, color) also gain
an opt-in `escape_control_chars` option (default `false`) for the same protection. See the
[Security](security.html) page for details.

#### `Formatters::Base#cleanse` renamed

The internal `SemanticLogger::Formatters::Base#cleanse` method was renamed to
`#escape_control_characters`. This only affects custom formatters or subclasses that called the old
method name directly; update them to call `#escape_control_characters`.

#### Rails: appenders are now configured in one block

If you use [rails_semantic_logger](rails.html), the companion gem's v5 release moves appender
configuration into a single `config.rails_semantic_logger.appenders do |appenders| ... end` block.
The v4 options (`format`, `add_file_appender`, `ap_options`, `filter`, `console_logger`) still work
but are deprecated and will be removed in v6. See
[Migrating from v4 to v5](rails.html#migrating-from-v4-to-v5) for the full before/after mapping.

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
