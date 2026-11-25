---
layout: default
title: Metrics
description: >-
  Count events, time code, and record values with increment, time, and record,
  independent of the log level, and send them once per interval to OpenTelemetry,
  StatsD, New Relic, SignalFx, or summary log entries.
---


**Contents**

* TOC
{:toc}

A **metric** is a named number that your application records about what it is doing: how often an
event happens, how long something takes, how large something is. Semantic Logger aggregates the
metrics on the thread that records them, and once per interval sends what was recorded to one or
more **metric appenders**, such as an OpenTelemetry collector, StatsD, New Relic, or SignalFx.

~~~ruby
SemanticLogger.add_appender(metric: :otlp)

logger.increment("users.signup")
logger.time("supplier.add_user") { supplier.add_user(user) }
logger.record("order.items", order.items.size)
~~~

## What changed in v6

**Metrics no longer depend on the log level once a metric appender is added.** In v5, a metric
rode along with its log entry, so a metric on a `:debug` call was never sent while the level was
`:info`, and each metric appender received one log entry per metric call. In v6:

* Every logger has `increment`, `time`, and `record`, which record a metric without logging
  anything, whatever the log level.
* The `metric:` of a log call or a `measure_*` call is recorded at every level, and whether or not
  its `min_duration:` is met. The log entry itself still follows the log level, as before.
* Metrics are aggregated in the process, as counters and histograms, and each metric appender is
  given what was recorded in each interval, 60 seconds by default, rather than one entry per call.
* Without a metric appender nothing changes: the metric calls return at once, and a `metric:` on a
  log call is only part of the log entry, as in v5.

See [Upgrading to Semantic Logger v6](upgrading.html#upgrading-to-semantic-logger-v6) for what this
means for an existing application.

> **Not to be confused with operational stats.** The metrics on this page are *application* metrics
> that your code records about what it is doing. To monitor Semantic Logger's *own* health, such as
> queue sizes and the number of log entries processed or dropped, use
> [`SemanticLogger.stats`](operations.html#monitoring-the-background-thread), or
> [internal metrics](#internal-metrics).

## Add a metric appender

Nothing is recorded until a metric appender is added, usually when the application starts:

~~~ruby
# An OpenTelemetry collector, or any OTLP/HTTP receiver:
SemanticLogger.add_appender(metric: :otlp, url: "http://localhost:4318")

# A StatsD server:
SemanticLogger.add_appender(metric: :statsd, url: "udp://localhost:8125")

# New Relic custom metrics, through the newrelic_rpm agent:
SemanticLogger.add_appender(metric: :new_relic)

# Splunk Observability Cloud (SignalFx):
SemanticLogger.add_appender(metric: :splunk_observability, token: "SIGNALFX_ORG_ACCESS_TOKEN")

# A summary of each interval, written as log entries by the log appenders:
SemanticLogger.add_appender(metric: :summary)

# One of your own (see Write a custom metric appender):
SemanticLogger.add_appender(metric: MyMetrics.new)
~~~

Every metric appender takes these options:

| Option | Description |
|--------|-------------|
| `interval:` | Seconds between the metrics it writes. Default: `60`. |
| `internal_metrics:` | Whether it also writes Semantic Logger's own metrics. Default: `false`. See [Internal metrics](#internal-metrics). |

~~~ruby
SemanticLogger.add_appender(metric: :statsd, url: "udp://localhost:8125", interval: 10)
SemanticLogger.add_appender(metric: :otlp, interval: 30, internal_metrics: true)
~~~

Metrics are collected at the shortest interval among the metric appenders present. An appender
with a longer interval merges the snapshots it is given until its own interval has passed, then
writes them at once.

A metric appender takes no log entries, so it refuses the options of an appender for log entries:
`level:`, `filter:`, `formatter:`, a formatter block, and `batch: true` raise `ArgumentError`. An
option given as `nil` sets nothing, so it is not refused. `:summary` takes `level:`, the level of
the log entries it writes. Add a metric appender with `async: true` to give it a thread of its own,
so that a slow destination holds up no other appender.

Once the last metric appender is removed, with `SemanticLogger.remove_appender`, metrics are no
longer collected, and the metric calls return at once again.

## Record metrics

Every logger has three metric methods. They log nothing, and do not depend on the log level.

### Count something: `increment`

`increment(name, amount = 1, unit: nil, dimensions: nil)` adds to a counter:

~~~ruby
logger.increment("users.signup")
logger.increment("cart.items_added", 3, dimensions: {department: "clothing"})
logger.increment("payments.amount", 189.42, dimensions: {currency: "USD"})
logger.increment("messaging.client.sent.messages", unit: "{message}")
~~~

`unit:` names what the counter counts, in the notation of OpenTelemetry (UCUM), such as
`"{message}"`, or `"By"` for bytes. As for `record`, it is part of the identity of the series. The
`:otlp` and `:summary` appenders send it; the others leave it out.

A counter only ever grows: its amount is zero or more. To count something that goes down, such as
items removed from a cart, give it a counter of its own:

~~~ruby
logger.increment("cart.items_removed")
~~~

### Time something: `time`

`time(name, duration: nil, dimensions: nil)` records a duration in a histogram, in seconds, with
the unit `"s"`. With a block, it times the block and returns the block's result. The time is
recorded however the block ends, including when it raises, which is raised again:

~~~ruby
user = logger.time("supplier.add_user", dimensions: {supplier: "acme"}) { supplier.add_user(params) }
~~~

Without a block, it records a duration measured elsewhere, given in milliseconds, like the
`duration:` of a log call:

~~~ruby
logger.time("sidekiq.queue.latency", duration: latency_ms)
~~~

With a block, `duration:` is ignored.

### Record any value: `record`

`record(name, value, unit: nil, dimensions: nil)` records a value in a histogram, such as a size or
a count of items, whose distribution (count, sum, minimum, maximum, and percentiles) the metric
appenders write:

~~~ruby
logger.record("order.items", order.items.size)
logger.record("upload.size", file.size, unit: "By")
~~~

The value may be negative. Give `unit:` in the notation that OpenTelemetry uses
([UCUM](https://ucum.org/ucum)), such as `"By"` for bytes, `"s"` for seconds, or `"{item}"` for a
count of items. The unit is part of what identifies a metric, so values in two units are never
combined.

### Return values

* `increment` and `record` return `true` once the metric is recorded, and `false` when no metric
  appender is present, or when the metric is dropped.
* `time` with a block returns the block's result. Without a block, it returns `true` or `false`, as
  `increment` does.

### Skip costly dimensions: `collecting_metrics?`

Without a metric appender, a metric call returns at once, but its arguments are still built. When
building the dimensions costs something, such as parsing a statement, ask the logger first:

~~~ruby
if logger.collecting_metrics?
  logger.time("db.client.operation.duration", duration: ms, dimensions: dimensions_of(sql))
end
~~~

`collecting_metrics?` answers for the whole process: `true` once a metric appender is present, in the
main Ractor only, and always for a test logger (see [Testing](testing.html)).

### They never raise

Like log calls, the metric calls never raise. A metric is dropped, with a warning on Semantic
Logger's internal logger (which writes warnings and errors to standard error by default), once per
metric name and problem, when:

* its name is not a non-empty String or Symbol (a Symbol name is recorded as a String, so `:jobs`
  and `"jobs"` are one metric);
* its value is not a real Numeric that is finite as a Float, such as `nil`, `Float::NAN`, or
  `Float::INFINITY`. The Integer amount of a counter is added exactly, however large;
* a counter is given a negative amount;
* its dimensions are neither `nil` nor a Hash;
* recording it fails, such as for a dimension value whose `#hash` raises.

~~~
W [1234:1488] SemanticLogger::Appenders -- Dropped counter "cart.items": a counter cannot be decreased, its amount -1 is negative. Further ones are dropped without a warning.
~~~

### Dimensions

Dimensions are key/value labels that break a metric down, such as by region, plan, or status. Each
combination of dimension values is a **series** of its own:

~~~ruby
logger.increment("filters.applied", dimensions: {plan: "premium", region: "eu-west"})
~~~

Keys are recorded as Strings, and so are Symbol values, so `{plan: :premium}` and
`{"plan" => "premium"}` are the same series. Other scalar values (Strings, Integers, Floats, `true`,
`false`, `nil`) are kept as they are, an Array of scalars as an Array, and any other value as text.

The dimensions of a metric are only the ones given to the call: the tags and named tags of the
thread, or of a logger returned by `tagged`, are never added to them, since each new value of a
dimension starts another series.

Not every destination takes dimensions: StatsD and New Relic record the series of a metric
together, under its name alone. See [Metric appenders](#metric-appenders).

[`SemanticLogger.sensitive_keys=`](security.html#metric-dimensions) redacts the dimensions too: the
value of a dimension whose key is sensitive is replaced, such as with `"[FILTERED]"`, once per
interval as the metrics are collected, and the series that differed only by that value are merged.
Only values are replaced, never keys, so never put a secret in a dimension, nor in its key. A
dimension key declared with `SemanticLogger.safe_dimension_keys` is never redacted (see
[Metric dimensions](security.html#metric-dimensions)).

### Keep the values of each dimension bounded

Give each dimension a small, fixed set of values, such as a status, a region, a plan, an HTTP
method, or the route of a request (`/users/:id`, not `/users/42`). Never use a value that grows
with your data or your traffic, such as a user id, an email address, an order or request id, an IP
address, a session, a timestamp, or a URL with ids in it.

A metrics backend keeps a separate time series for every combination of dimension values that it
receives under one metric name, and most count each one as a metric of its own:

* [Datadog](https://docs.datadoghq.com/account_management/billing/custom_metrics/) identifies a
  custom metric by its name together with its tag values, so each combination is billed as a
  custom metric.
* [SignalFx](https://help.splunk.com/en/splunk-observability-cloud/manage-data/metrics-metadata-and-events/metrics-events-and-metadata/get-started-with-metrics)
  (Splunk Observability Cloud) keeps a metric time series (MTS) for each combination of a metric
  and its dimensions. The active ones count toward a
  [limit](https://help.splunk.com/en/splunk-observability-cloud/administer/org-reference-info/per-product-system-limits-in-splunk-observability-cloud/infrastructure-system-limits-details)
  that your subscription sets, beyond which it refuses new time series without an error, so new
  values stop being recorded.
* [Google Cloud Monitoring](https://docs.cloud.google.com/monitoring/api/v3/metric-model#cardinality)
  keeps a time series for each combination of label values, and asks that the values of every
  label be constrained: no unique identifiers, user ids, IP addresses, timestamps, or URLs that
  are not parameterized.

The combinations multiply: a metric with a `status` of 5 values, a `region` of 4, and a `plan` of 3
can make up to 60 time series. Add a `user_id` dimension for 10,000 users, and the same metric can
make up to 600,000, each one billed or counted against a limit.

To find what happened to one user, order, or request, log its id in the
[payload](api.html#step-3-add-structured-data) of a log entry instead, where a log appender stores
it with that entry rather than as a metric of its own.

### Metric names

Name metrics as [OpenTelemetry](https://opentelemetry.io/docs/specs/semconv/general/naming/) does:
lowercase words separated by dots, from the general to the specific, such as `users.signup`,
`supplier.add_user`, or `http.server.request.duration`. Do not put the unit in the name; give it
with `unit:` instead.

Put the variable parts of a metric in its dimensions, never in its name: not
`"users.#{plan}.signup"`, but `logger.increment("users.signup", dimensions: {plan: plan})`. A name
built from an id, as in `"users.#{user.id}.fetch"`, makes a new metric for every user.

### Limits

So that a mistake in the application cannot use up the memory of the process, each interval holds
at most:

* **2000 metrics**, each a metric name recorded by the logger of one class, so a name recorded by
  the loggers of two classes counts twice. A record of a further metric is dropped, and the internal
  logger reports it once per interval, naming the first name dropped: "Put variable parts in
  dimensions: instead of the metric name."
* **2000 series per metric**, of each class, so a metric appender without scopes (see
  [OpenTelemetry](#opentelemetry-otlp)) may be given more series of a name recorded by several classes. The values of further dimension combinations are added to one
  overflow series, whose dimensions are `{"otel.metric.overflow" => true}`, as OpenTelemetry names
  it, so that the totals of the metric stay right.

Within one interval a metric name has one kind (counter or histogram) and one unit, in the loggers
of every class: the first record of the name decides them. A later record of the same name with
another kind or unit, such as `increment("jobs")` after `time("jobs")`, is dropped, with a warning
on the internal logger once per metric name. Give each metric name one kind and one unit.

## Metrics on log and measure calls

A log call or a `measure_*` call can still record a metric with `metric:`, as in v5:

~~~ruby
logger.info("Signed up", metric: "users.signup")
logger.info(message: "Purchase complete", metric: "departments.purchases", metric_amount: 189.42)
logger.info(message: "Called supplier", metric: "supplier.add_user", duration: 100.23)

logger.measure_info("Called supplier", metric: "supplier.add_user", dimensions: {supplier: "acme"}) do
  supplier.add_user(user)
end
~~~

Once a metric appender is present, the metric is recorded:

* as a histogram of its `duration:` in seconds, with the unit `"s"`, when it has a duration, as a
  `measure_*` call always does, the same as `logger.time`;
* otherwise as a counter of its `metric_amount:`, 1 by default, the same as `logger.increment`;
* with its `dimensions:`, plus `"error.type"`, the class name of the exception, when the block of a
  `measure_*` call raises, so that failed calls are a series of their own, as the OpenTelemetry
  semantic conventions name it, unless its dimensions already have one. An exception class without a
  constant name, such as `Class.new(StandardError)`, is named after its nearest superclass that has
  one, so that it does not add a series for each class. The log entry keeps its own dimensions;
* **at every level**, whether or not the log entry is logged, and whether or not its
  `min_duration:` is met, or a filter rejects the entry. The log entry itself still follows the log
  level and filters, and is written as before.

Below the log level, a `measure_*` call times its block only when its options have a `metric:`
before the call, so a `metric:` that the block adds to the options (or a logging block returns) is
recorded only when the level passes:

~~~ruby
# Timed and recorded at every level:
logger.measure_debug("Called supplier", metric: "supplier.add_user") { supplier.add_user(user) }

# Recorded only while the level is :debug or below, since the metric is added by the block:
logger.measure_debug("Called supplier") do |params|
  params[:metric] = "supplier.add_user"
  supplier.add_user(user)
end
~~~

A negative `metric_amount` is not recorded: the log entry is still written with it, but its metric
is dropped, with a warning on the internal logger once per metric name.

Without a metric appender, a `metric:` is only part of its log entry, as in v5: see
[Metrics in log appenders](#metrics-in-log-appenders).

## Histograms

`time`, `record`, and the `metric:` of a call with a duration record into a histogram rather than
keeping every value. Each series has an OpenTelemetry
[base-2 exponential histogram](https://opentelemetry.io/docs/specs/otel/metrics/data-model/#exponentialhistogram):

* It starts at scale 3, where each power of two is split into 8 buckets, each about 9% wider than
  the one below it, so that a percentile estimated within a bucket is within about 4.5% of the
  value.
* It holds at most 160 buckets for positive values, and 160 for negative ones, enough at scale 3
  for values spanning 20 powers of two, a factor of about a million, such as from 1 ms to 17
  minutes. Values spanning more lower the scale, merging neighbouring buckets, so any range of
  values fits, less precisely.
* It also keeps the exact count, sum, minimum, and maximum of the values.
* Durations are recorded in seconds, the unit OpenTelemetry uses, and each appender converts them
  to the unit its destination expects, such as milliseconds for StatsD and SignalFx.

Each interval starts every histogram afresh: the metrics of each interval are deltas, never totals
since the process started.

## Intervals, flushes, and outages

Metrics are collected on a thread of their own, named `SL Metrics`, once per interval. Each metric
appender is given a snapshot of what was recorded since the previous one, on the thread that writes
its log entries, or on its own thread when added with `async: true`.

**A flush ends the interval.** `SemanticLogger.flush`, including the flush at exit, gives the metric
appenders what was recorded so far, and each writes what it holds, a partial interval. So does
removing a metric appender, for that appender. A process that flushes at the end of each unit of
work, such as an AWS Lambda function or a job runner, therefore exports its metrics at each flush:

~~~ruby
def handler(event:, context:)
  logger.time("orders.import") { import(event) }
ensure
  SemanticLogger.flush # The metrics of this invocation are written now
end
~~~

**Forked processes** each report their own metrics: after a fork, the child discards the series it
inherited, which the parent still reports, and records its own from then on. A child started by
`Process.daemon`, whose parent exits, keeps them.

**Outages.** A snapshot that an appender fails to write is reported on the internal logger and
discarded, unless the appender says that writing it again may succeed: `:otlp` and `:signalfx`
keep a snapshot that the server could not be reached for, or asked to be sent again later, and
write it with the next one, merged into one. One that the server answered with a failure is kept at
most 3 times in a row. One that was never sent is kept for as long as the outage lasts, within two
limits:

| Limit | Value | Description |
|-------|-------|-------------|
| `SemanticLogger::Metric::Snapshots::MAX_KEPT_POINTS` | `10_000` | Most series that a kept snapshot may hold. |
| `SemanticLogger::Metric::Snapshots::MAX_KEPT_SECONDS` | `3600` | Most seconds that a kept snapshot may span, from the start of its oldest interval. |

Beyond either limit, it is discarded, with an error on the internal logger, so that an outage
neither grows the process without bound nor sends a burst of stale metrics once it ends. A flush, or
closing the appender, writes what it holds and keeps once, and discards it when that fails.

**Ractors.** On Ruby 4.0 and later, metric calls made in a Ractor other than the main one are
dropped.

## Metric appenders

### OpenTelemetry (OTLP)

Sends the metrics of each interval to an OpenTelemetry collector, or any other receiver of
OTLP/HTTP, such as Grafana Alloy, Datadog, Honeycomb, or New Relic's OTLP endpoint, in OTLP's binary
Protobuf encoding (`http/protobuf`), or as OTLP/JSON (`http/json`). It needs no OpenTelemetry gems,
nor the `google-protobuf` gem.

~~~ruby
SemanticLogger.add_appender(metric: :otlp)

SemanticLogger.add_appender(
  metric:              :otlp,
  url:                 "https://otlp.example.com",
  header:              {"Authorization" => "Bearer TOKEN"},
  resource_attributes: {"service.version" => "1.2.3"},
  interval:            10
)
~~~

Each snapshot is posted as one `ExportMetricsServiceRequest` to `<url>/v1/metrics`: counters as
monotonic sums, and histograms as base-2 exponential histograms, both with delta temporality. A
histogram that recorded a negative value is sent without its sum, as OTLP asks, since a receiver takes
the sum as one that only grows.

The metrics of each logger are sent in an instrumentation scope (a meter) named after the logger,
such as `MyApp::Orders`, as the log records of [`appender: :otlp`](appenders.html) are, so the
metrics of `MyApp::Orders` are sent apart from those of `MyApp::Payments`, even with the same name.
A receiver that keeps scopes apart, such as Prometheus with its `otel_scope_name` label, then has a
series for each class that records a name; one that ignores the scope may take two of them, with the
same name and attributes, as one. The metrics of a logger without a name, such as that of an
anonymous class, are in a scope without a name, as its log records are. Semantic Logger's own
metrics are in the scope `SemanticLogger`,
with the gem's version. Within a scope, each kind, name, and unit is sent as one OTLP metric, with a
data point for each of its series. A snapshot that merges several intervals, during an outage, may
hold one name in two units: each is sent as a metric of its own.

The other metric appenders have no scopes: the series that loggers of different classes record with
the same name and dimensions are merged into one before they are written.

| Option | Description |
|--------|-------------|
| `url:` | Base url of the receiver; the metrics are posted to `v1/metrics` under its path. Default: `OTEL_EXPORTER_OTLP_ENDPOINT`, or else `http://localhost:4318`. |
| `endpoint:` | The full url to post the metrics to, used as it is, instead of `url:`. Default: `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`, unless `url:` is given. |
| `protocol:` | `"http/protobuf"` or `"http/json"`. Default: `OTEL_EXPORTER_OTLP_METRICS_PROTOCOL`, or else `OTEL_EXPORTER_OTLP_PROTOCOL` (in any case), or else `"http/protobuf"`. A `Content-Type` given in `header:` of another type raises `ArgumentError`: choose the encoding with `protocol:`. |
| `application:` | The `service.name` of the resource. Default: `OTEL_SERVICE_NAME`, or else `SemanticLogger.application`. |
| `host:` | The `host.name` of the resource. Default: `SemanticLogger.host`. |
| `environment:` | The `deployment.environment.name` of the resource, left out when there is none. Default: `SemanticLogger.environment`. |
| `resource_attributes:` | More attributes of the resource, which replace those above with the same key, and those of `OTEL_RESOURCE_ATTRIBUTES`. |
| `header:` | Headers to send with each request, such as one with credentials. Default: `OTEL_EXPORTER_OTLP_METRICS_HEADERS`, or else `OTEL_EXPORTER_OTLP_HEADERS`; a header given wins over one of the environment with the same name, in any case. See below for the headers of the environment. |
| `compress:` | `true` to compress each request with gzip. Default: `true` when `OTEL_EXPORTER_OTLP_METRICS_COMPRESSION`, or else `OTEL_EXPORTER_OTLP_COMPRESSION`, is `gzip`, otherwise `false`. |
| `open_timeout:`, `read_timeout:` | Seconds to wait to connect, and for each read of the response. Default: `OTEL_EXPORTER_OTLP_METRICS_TIMEOUT`, or else `OTEL_EXPORTER_OTLP_TIMEOUT`, in milliseconds (`0` for no limit), only when neither option is given; otherwise those of the HTTP appender. |
| `export_timeout:` | Seconds that the export of each snapshot may take in all, from encoding it to the end of the response; `0` for no limit. Each step of connecting (the TCP connection, then any TLS handshake), sending the request, and each read of the response are bounded by the time left, as well as by `open_timeout:` or `read_timeout:`, each capped separately, so a receiver that stalls at each step, or answers a byte at a time, can hold an export for a few times `export_timeout:`. A snapshot whose time ran out before its request was sent is sent with the next one; once sent, it is discarded, since the receiver may have stored it. Default: `OTEL_METRIC_EXPORT_TIMEOUT`, in milliseconds (`0` for no limit), or else `30`, as in the OpenTelemetry metrics SDK. |
| `ssl:`, `proxy_url:`, ... | The other options of the [HTTP appender](appenders.html#https). |

Every request also has the `process.pid` of the process that sends it, so that the deltas of each
process, such as the forked workers of one application on one host, are kept apart. Only
`resource_attributes:` can replace it; a `process.pid` in `OTEL_RESOURCE_ATTRIBUTES`, which every
process shares, is left out, with a warning.

It connects to the receiver when it is added, as every appender built on the HTTP appender does.
When it cannot, such as while the receiver is not listening yet as the application starts, it
reports that to the internal logger rather than raising, and the next request connects. A snapshot
that could not be sent follows [Outages](#intervals-flushes-and-outages).

Of the [OpenTelemetry exporter environment variables](https://opentelemetry.io/docs/specs/otel/protocol/exporter/),
it reads those below, each only when the matching option is not given. An empty variable counts as
not set, and the `_METRICS_` form of a variable replaces its generic form as a whole, without merging.

| Variable | Sets |
|----------|------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `url:` |
| `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` | `endpoint:` |
| `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_METRICS_HEADERS` | `header:`, as `name=value` pairs separated by commas, trimmed and percent-decoded, such as `api-key=abc%3D,x-team=core`. |
| `OTEL_EXPORTER_OTLP_TIMEOUT`, `OTEL_EXPORTER_OTLP_METRICS_TIMEOUT` | `open_timeout:` and `read_timeout:`, in whole milliseconds; `0` means no limit. Used only when neither option is given, so that one given keeps the HTTP appender's default for the other. |
| `OTEL_EXPORTER_OTLP_COMPRESSION`, `OTEL_EXPORTER_OTLP_METRICS_COMPRESSION` | `compress:`: `true` for `gzip`, `false` for `none`, in any case. |
| `OTEL_EXPORTER_OTLP_PROTOCOL`, `OTEL_EXPORTER_OTLP_METRICS_PROTOCOL` | `protocol:`: `http/protobuf` or `http/json`. `grpc` sends `http/protobuf`, with a warning, since the appender speaks OTLP/HTTP only: give it the url of an OTLP/HTTP receiver, such as port 4318 rather than gRPC's 4317. |
| `OTEL_EXPORTER_OTLP_CERTIFICATE`, `OTEL_EXPORTER_OTLP_METRICS_CERTIFICATE` | The `ca_file:` of `ssl:`: the file of trusted certificates to verify the receiver with. |
| `OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE`, `OTEL_EXPORTER_OTLP_METRICS_CLIENT_CERTIFICATE` | The `cert:` of `ssl:`: the PEM file of the client's certificate, for mutual TLS. |
| `OTEL_EXPORTER_OTLP_CLIENT_KEY`, `OTEL_EXPORTER_OTLP_METRICS_CLIENT_KEY` | The `key:` of `ssl:`: the PEM file of the client's private key, for mutual TLS. |
| `OTEL_METRIC_EXPORT_INTERVAL` | `interval:`, in whole milliseconds. |
| `OTEL_METRIC_EXPORT_TIMEOUT` | `export_timeout:`, in whole milliseconds; `0` means no limit. |
| `OTEL_SERVICE_NAME` | `application:` |
| `OTEL_RESOURCE_ATTRIBUTES` | Attributes of the resource, as `key=value` pairs separated by commas, trimmed and percent-decoded, each value a String, other than `process.pid`. |

The attributes of the resource come from, highest first: `resource_attributes:`; `application:`,
`host:`, and `environment:` when given, and `OTEL_SERVICE_NAME`; `OTEL_RESOURCE_ATTRIBUTES`; then
`SemanticLogger.application`, `.host`, and `.environment`.

The headers of the environment are sent to whatever url the appender posts to, including a `url:`
or `endpoint:` given, as the OpenTelemetry specification asks. Since they often hold credentials,
make sure they are meant for that receiver. `header: {}` does not stop them; to send none, do not set
`OTEL_EXPORTER_OTLP_HEADERS` or `OTEL_EXPORTER_OTLP_METRICS_HEADERS` for the process. A header of the
environment named, in any case, as one of the headers the HTTP appender sets itself, such as
`Content-Type`, `Accept`, `Content-Encoding`, `Accept-Encoding`, and `Authorization` when it sends
basic auth, is left out, with a warning that names it.

A value it cannot use is ignored, with a warning on the internal logger: a variable that is not valid
UTF-8 (named, never its value), a timeout or export timeout that is not a whole number of milliseconds,
an export interval that is not a positive whole number of milliseconds, a protocol other than
`http/protobuf`, `http/json`, or `grpc`, or a compression other than `gzip` or `none`. A malformed
header entry, such as one without `=`, with a name that is not a valid header name, or with a value that
holds anything other than printable ASCII and tabs once percent-decoded, is left out, and the warning
names its position only, never its text, since a header may hold credentials. A malformed
`OTEL_RESOURCE_ATTRIBUTES` is ignored as a whole, as the OpenTelemetry specification asks.

The certificate variables apply to an `https` url only. A `ca_file:`, `ca_path:`, or `cert_store:`
given in `ssl:` wins over the certificate variable, and a `cert:` or `key:` given over both client
variables, which are taken only as a pair; a variable whose option is given is not read. A
certificate file that cannot be read, or that does not hold PEM certificates, one of the client
variables without the other, or a key that is public, not the private key of its certificate, or has
a pass phrase, raises `ArgumentError` from `add_appender`, naming the variables, since every request
would fail without it. Only the first certificate of the client certificate file, the client's own,
is sent.

OTLP's timeout bounds a whole export, while the HTTP appender bounds connecting and each read of the
response instead, so a request can take somewhat longer than the timeout in all. To bound the whole
export, the appender has `export_timeout:`, from `OTEL_METRIC_EXPORT_TIMEOUT`: each wait on the
receiver is capped at the time left when it starts, separately, so a receiver that stalls at each step
can still hold an export for a few times `export_timeout:`.

**Responses.** A snapshot that the receiver asks to send again (408, 429, 502, 503, or 504), or that
could not be sent since the receiver could not be reached, is sent again with the next one (see
[Outages](#intervals-flushes-and-outages)); any other failure is reported on the internal logger,
and the snapshot discarded. A partial success, where the receiver stored only some of the data
points, is reported on the internal logger, and not sent again.

> **Note:** a 502 or 504 from a proxy or load balancer in front of the receiver may come after the
> receiver stored the snapshot, such as when it answered later than the proxy waits. Sending it
> again, as OTLP/HTTP requires, then counts its data points twice.

### StatsD

Sends the metrics of each interval to a [StatsD](https://github.com/statsd/statsd) server over UDP
(requires the `statsd-ruby` gem):

~~~ruby
SemanticLogger.add_appender(metric: :statsd, url: "udp://localhost:8125", interval: 10)
~~~

The `url:` must be `udp://`, and its host must resolve when the appender is added, or
`add_appender` raises. A path in the url, as in `udp://localhost:8125/my_app`, is the namespace of
every metric. Default: `udp://localhost:8125`.

* **Counters** are sent as one packet per metric name per interval, `users.signup:12|c`. StatsD
  counters are Integers, so the amount is rounded, and the fraction left over is added to the
  counter's next interval, so that fractional amounts add up. A name with no amount in the next
  interval drops its fraction. A zero amount is not sent.
* **Histograms**: StatsD has no histogram type, so a histogram is sent as one timer packet per
  non-empty bucket, at the bucket's midpoint, with 1 / the bucket's count as the sample rate:
  `supplier.add_user:61.2|ms|@0.04`. A server that applies sample rates weights it as that many
  timings, as the Datadog agent and Telegraf do, so their counts and percentiles match the values
  recorded, within the width of a bucket. The original etsy statsd counts them the same way, but
  leaves the sample rate out of its percentiles, so its percentiles weight each bucket once.
  Durations are sent in milliseconds; any other histogram in its own unit.
* **Dimensions** are left out, since `statsd-ruby` has no tags: the series of a metric name are
  added together (counters) or merged (histograms), and sent under the name alone.
* The packets are sent without client-side sampling, as many as fit in each 1432-byte datagram.
* A `:`, `|`, or `@`, a line break, a character that is not ASCII, or an invalid byte, in a metric
  name is sent as `_`, whatever the name's encoding, and `::` as `.`.

### New Relic

Records the metrics of each interval as New Relic custom metrics, through the agent (requires the
`newrelic_rpm` gem):

~~~ruby
SemanticLogger.add_appender(metric: :new_relic)
SemanticLogger.add_appender(metric: :new_relic, prefix: "Custom/MyApp")
~~~

* A **counter** is recorded with `NewRelic::Agent.increment_metric(name, sum)`, once per interval.
* A **histogram** is recorded with `NewRelic::Agent.record_metric(name, {count:, total:, min:, max:,
  sum_of_squares:})`, one pre-aggregated value per interval, durations in seconds, as New Relic
  expects. The sum of squares is estimated from the histogram's buckets, never below what the count
  and total allow.
* New Relic charts custom metrics only under `Custom/`, so `prefix:`, `"Custom"` by default, is
  added with a `/` to every name that does not already start with it: `users.signup` is recorded
  as `Custom/users.signup`, and `Custom/Orders/placed` as it is. Another prefix should start with
  `Custom/` too.
* **Dimensions** are left out, since the agent's metric API takes none: the series of a metric are
  merged under its name.
* A counter whose sum, or a histogram whose total, is beyond the range of a Float is left out of its
  interval, with a warning on the internal logger once per name. A sum of squares beyond that range
  is recorded as the largest Float, `Float::MAX`, so that the histogram's count, total, minimum, and
  maximum are still recorded.

### Splunk Observability Cloud (SignalFx) {#signalfx}

Posts the metrics of each interval to the
[Splunk Observability Cloud](https://www.splunk.com/en_us/products/infrastructure-monitoring.html)
ingest API, formerly SignalFx, `v2/datapoint`, in one request, with the end of the interval as the
timestamp:

~~~ruby
SemanticLogger.add_appender(metric: :splunk_observability, token: "SIGNALFX_ORG_ACCESS_TOKEN")
~~~

`metric: :signalfx`, its former name, adds the same appender, which names itself
`SemanticLogger::Metric::Signalfx` in its reports and errors, whichever name added it.

| Option | Description |
|--------|-------------|
| `token:` | The organization access token. Required. |
| `url:` | The ingest url. Default: `https://ingest.signalfx.com`. |
| `host:`, `application:`, `environment:` | Sent as dimensions of every datapoint (`environment` only when set). Default: `SemanticLogger.host`, `.application`, `.environment`. |

Each **counter** series is sent as a `counter` datapoint of what was added to it in the interval.
SignalFx takes no histograms in this API, so each **histogram** series is sent as:

| Name | Type | Value |
|------|------|-------|
| `<name>` | gauge | The mean |
| `<name>.count` | counter | The number of values recorded in the interval |
| `<name>.sum` | counter | Their sum |
| `<name>.min`, `<name>.max` | gauge | The smallest and the largest |
| `<name>.p50`, `<name>.p95`, `<name>.p99` | gauge | The percentiles, estimated from the histogram |

Durations are sent in milliseconds, as v5 sent them, so that existing charts keep their scale.

**Names with a `/`.** A `/` in a name is sent as `.`, and a leading, trailing, or repeated `/` is
left out; a series whose name is then empty is not sent, with a warning. A series whose name has a
`/` and that has no dimensions is sent as v5 sent such a metric, so that existing charts keep
working: the metric is named `Application`, with the dimensions `class` and `action` taken from
its name. A counter `Common/User/authorize` is sent as the counter `Application.counter` with
`class: "Common::User", action: "authorize"`; a histogram of that name as `Application.counter`
(the count), `Application.average` (the mean), and `Application.sum`, `Application.min`, ...
`Application.p99`. Any other name, such as `users.signup`, is sent as it is.

**Dimensions.** Each datapoint has the dimensions of its series, each value as text, and the
`host`, `application`, and `environment` of the appender, unless the metric has a dimension of that
name of its own, which it keeps. The appender's `host` keeps the series of each host apart, since
SignalFx keeps one value of a series for each timestamp: a metric that sets `host` itself is sent
by every host into the same series, where one host's values replace another's, unless another of
its dimensions tells them apart. A dimension whose value is blank, `nil` or text that is empty or
only whitespace, is left out; dimensions that are all blank count as none.
SignalFx itself accepts at most 36 dimensions on a datapoint, dimension names of up to 128
characters, and values of up to 256 characters; Semantic Logger sends the dimensions as they are,
so keep them within those limits.

The histogram series that are sent with the same name and non-blank dimensions, such as those of
`a/b` and `a.b` with the same dimensions, are merged first; a series with a unit other than that of
the first one merged is left out, with a warning. (`a/b` and `a.b` without dimensions are not
merged, since `a/b` is then sent as `Application`.)

**Name collisions.** Avoid giving a metric one of the names that a histogram is sent as:

* A counter named as one of the counters of a histogram, such as a counter `latency.count` and a
  histogram `latency`, is sent as one counter holding both.
* A request holds one datapoint for each name and dimensions, so a gauge with the name and
  dimensions of a datapoint already in the request, or a counter with those of a gauge, such as the
  gauge `latency.max` of a histogram `latency` and a counter `latency.max`, is left out, keeping the
  first one, with a warning.

A value beyond the range of a Float, such as the sum of a histogram of huge values, is left out,
with a warning. Each of these warnings is made once per metric name, on the internal logger.

It connects to the ingest url when it is added, as every appender built on the HTTP appender does.
When it cannot, it reports that to the internal logger rather than raising, and the next request
connects. A snapshot that the server asks to send again later (408, 429, or 503), or that could not
reach it, is sent with the next one (see [Outages](#intervals-flushes-and-outages)).

### Summary log entries

Writes the metrics of each interval as log entries, one per series, so that every log appender,
such as a file, standard output, or a JSON log service, writes them with its own formatter. Useful
in development, or where no metrics backend is available:

~~~ruby
SemanticLogger.add_appender(metric: :summary)
SemanticLogger.add_appender(metric: :summary, interval: 300, level: :debug)
~~~

~~~
2026-11-20 14:40:33.477268 I [44925:SL Appenders] SemanticLogger::Metric::Summary -- users.signup -- {sum: 1}
2026-11-20 14:40:33.477277 I [44925:SL Appenders] SemanticLogger::Metric::Summary -- cart.items_added -- {sum: 3, dimensions: {"department" => "clothing"}}
2026-11-20 14:40:33.477279 I [44925:SL Appenders] SemanticLogger::Metric::Summary -- supplier.add_user -- {count: 50, sum: 4.18, min: 0.01, max: 0.157, p50: 0.0834, p95: 0.15, p99: 0.156, unit: "s"}
~~~

Each entry is named `SemanticLogger::Metric::Summary`, its message is the metric name, and its
payload holds the `sum` of a counter, or the `count`, `sum`, `min`, `max`, `p50`, `p95`, and `p99`
of a histogram, with the `unit` and `dimensions` of either when it has them. Values are rounded to 3
significant digits, and the percentiles are estimates.

Its `level:`, `:info` by default, is the level of the entries it writes, independent of
`SemanticLogger.default_level`: each log appender writes them when they are at or above its own
level. The entries carry no tags, named tags, or metric.

## Internal metrics

A metric appender added with `internal_metrics: true` also writes Semantic Logger's own metrics.
Metric appenders without it never see them, and logging pays nothing for them until one is added.

~~~ruby
SemanticLogger.add_appender(metric: :otlp, internal_metrics: true)
~~~

There is one counter, named as OpenTelemetry names the counter of its own log processors:

| Name | Unit | Dimensions |
|------|------|------------|
| `semantic_logger.log.processed` | `{log_record}` | `appender`, and `error.type` for the entries not written |

It counts the log entries that each queue finished with in the interval:

* `appender`: `"main"` for the main queue, otherwise the name of an appender with a queue of its
  own, added with `async: true` or in batches, as `"<name>#2"` for a second one with the same name.
* `error.type`: `"dropped"` for the entries dropped because the queue was full, `"failed"` for
  those discarded because they could not be written. Absent for the entries written.

They are read from [`SemanticLogger.stats`](operations.html#monitoring-the-background-thread) at
each collection.

## Write a custom metric appender

A metric appender is a `SemanticLogger::Subscriber`, or a subclass of one such as
`SemanticLogger::Appender::Http`, that includes `SemanticLogger::Metric::Snapshots` and implements
`write_metrics(snapshot)`, which writes the snapshot of an interval to the destination. It returns
once the destination has it, and raises when it could not write it:

~~~ruby
class MyMetrics < SemanticLogger::Subscriber
  include SemanticLogger::Metric::Snapshots

  def initialize(client:, **args)
    @client = client
    # Passes interval: and internal_metrics: on to Metric::Snapshots
    super(**args)
  end

  def write_metrics(snapshot)
    snapshot.each do |point|
      if point.counter?
        @client.count(point.name, point.value, tags: point.dimensions)
      else
        histogram = point.value
        @client.distribution(
          point.name,
          count: histogram.count,
          sum:   histogram.sum,
          min:   histogram.min,
          max:   histogram.max,
          p99:   histogram.quantile(0.99),
          unit:  point.unit,
          tags:  point.dimensions
        )
      end
    end
  end

  # Optional: whether each point keeps its scope, point.scope, the name of the logger that recorded it,
  # for a destination with scopes. False by default: the series that differ only by their scope are
  # merged, and point.scope is nil.
  def metric_scopes?
    false
  end

  # Optional: whether a snapshot that failed with this exception is worth writing again, with the
  # next one. False by default: it is reported and discarded.
  def metrics_retryable?(exception)
    exception.is_a?(MyClient::Unavailable)
  end

  # Writes the snapshots it holds first, with super, then flushes the client that they were given to.
  def flush
    super.tap { @client.flush }
  end
end

SemanticLogger.add_appender(metric: MyMetrics.new(client: client, interval: 10))
~~~

An appender that defines its own `initialize` passes the `interval:` and `internal_metrics:`
options on to `super`; one that defines its own `flush`, `close`, or `reopen` calls `super` from it,
so that a flush writes what the appender holds, and a forked child discards what it inherited. A
`flush` or `close` calls `super` first, then flushes or closes its client, so that the snapshots
that `super` writes reach the client before it is flushed or closed, and returns what `super`
returns.
`metrics_retryable?` should answer true only when the destination stored none of the snapshot,
otherwise writing it again counts its points twice; an appender that writes a snapshot in more than
one request must answer false for a failure of any request after the first.

An appender that carries state of its own from one snapshot to the next, such as the fractions of
counters that the StatsD appender rounds, overrides the private `forget_parent_state` to clear it.
It is called in a forked child, other than one started by `Process.daemon`, before the child writes
any snapshot, while the snapshots it inherited are discarded.

A `SemanticLogger::Metric::Snapshot` is frozen, and holds the metrics of one interval:

| Method | Returns |
|--------|---------|
| `start_time`, `end_time` | The start and end of the interval, as `Time`. |
| `each { \|point\| }`, `points` | Each `Point`, one per series. A snapshot is `Enumerable`. |
| `size`, `empty?` | The number of series, and whether there are none. |
| `merged_by { \|point\| key }` | A Hash of `[kind, unit, value]` for each key that the block gives, merging the points with that key: the sum of their counter values, or one histogram merging theirs. The first point of a key gives it its kind and unit; a later point with another kind or unit is left out. For a destination that keys its metrics by less than a series, such as by name alone, as StatsD and New Relic do. |

Each `SemanticLogger::Metric::Snapshot::Point` is frozen too:

| Method | Returns |
|--------|---------|
| `kind`, `counter?`, `histogram?` | `:counter` or `:histogram`. |
| `name` | The metric name, a String. |
| `unit` | The unit, such as `"s"` or `"By"`, or `nil`. |
| `dimensions` | A frozen Hash with String keys, empty when the series has none, with the values of sensitive keys already redacted (see [Metric dimensions](security.html#metric-dimensions)). |
| `value` | For a counter, the sum of its amounts in the interval (an Integer while every amount was an Integer, otherwise a Float); for a histogram, a `SemanticLogger::Metric::ExponentialHistogram`. |
| `internal?` | Whether it is one of Semantic Logger's own metrics. |
| `overflow?` | Whether it is the overflow series of its metric (see [Limits](#limits)). |

An `ExponentialHistogram` answers `count`, `sum`, `min`, `max`, `empty?`, `quantile(probability)`
(an estimate, such as `quantile(0.95)`), `sum_of_squares` (an estimate), `scale`,
`each_bucket { |lower, upper, count| }` for each non-empty bucket, and
`explicit_bucket_counts(bounds)` for the counts of the explicit buckets with those upper bounds,
such as a Prometheus histogram takes (approximate when a bound falls inside a bucket). Durations
are in seconds.

An appender that only implements `#log`, as a v5 metric subscriber did, is never given a snapshot:
it is a log appender, and receives the log entries that pass its level and filters, as before.

## Metrics in log appenders

Metric appenders are the destinations for metrics. Log [appenders](appenders.html) treat the
`metric:` of a log call as part of the log entry that carries it, whether or not a metric appender
is present. The metric calls `increment`, `time`, and `record` make no log entry, so log appenders
never see them.

* **A metric on an entry with a message or an exception** is written with the entry by the
  formatters that write structured data, so a log store such as Elasticsearch or Splunk can chart
  it without a metric appender. The text formatters do not write it; they show only the
  entry's duration.
* **A metric-only entry**, one with a metric but no message and no exception, such as
  `logger.info(metric: "users.signup")`, is meant for the metrics. There can be many such entries,
  so log appenders leave them out, unless one is added with `metrics: true`:

  ~~~ruby
  # Also index metric-only entries in Elasticsearch:
  SemanticLogger.add_appender(appender: :elasticsearch, url: "http://localhost:9200", metrics: true)
  ~~~

What each formatter writes for a metric on an entry with a message:

| Formatter | Metric fields written |
|-----------|-----------------------|
| `:json`, `:raw`, `:fluentd`, `:syslog_cee`, `:new_relic_logs` | `metric`, `metric_amount`, and `dimensions` |
| `:ecs` | `metric`, `metric_amount`, and `dimensions`, under its namespace, `semantic_logger` by default, or in `labels` when it has none |
| `:loki` | `metric`, `metric_value`, and `dimensions` (as JSON), in the structured metadata |
| `:otlp` | The `semantic_logger.metric` and `semantic_logger.metric_amount` attributes, and a `semantic_logger.dimensions.<key>` attribute for each dimension |
| `:default`, `:color`, `:one_line`, `:pattern`, `:syslog`, `:logfmt` | None; only the duration is shown |

An appender writes what its formatter writes. For example `:elasticsearch`, `:opensearch`,
`:splunk_http`, `:mongodb`, and `:graylog` use `:raw` by default, and `:http`, `:tcp`, `:udp`,
`:kafka`, `:rabbitmq`, and `:cloudwatch_logs` use `:json`.

## Test metrics

`SemanticLogger::Test::CaptureLogEvents` captures each metric call as it is made, before it is
aggregated, whether or not a metric appender is present: `increment`, `time`, `record`, and the
`metric:` of log and `measure_*` calls at every level. A metric that would be dropped, such as a
negative counter amount, is not captured. See [Testing](testing.html) for capturing log entries.

Each captured call is a `SemanticLogger::Test::MetricEvent`, with the attributes `kind` (`:counter`
or `:histogram`), `name` (a String), `value` (seconds for `time`), `unit`, and `dimensions` (as they
are recorded: String keys, Symbol values as Strings, `nil` for none, including an empty Hash).

### Minitest

With `include SemanticLogger::Test::Minitest`, `semantic_logger_metrics` returns the metric calls
made in its block, and `assert_metric` asserts that one of them has all the given attributes, and
returns it:

~~~ruby
it "counts sign ups" do
  metrics = semantic_logger_metrics { Signup.new.call(user) }

  assert_metric(metrics, name: "users.signup", kind: :counter, value: 1)
  assert_metric(metrics, name: "supplier.add_user", kind: :histogram, unit: "s", value: Float)
  assert_metric(metrics, name: "order.items", value: 1..10, dimensions: {plan: "free"})
end
~~~

An expected value matches when it is equal, when it is a Class, Range, Regexp, or Proc that matches
the value (with `===`), or, as `:nil`, when the attribute is nil. Expected `dimensions:` are compared
as they are recorded, so `{plan: "free"}` matches `{"plan" => "free"}`, and `{}` matches none.
Attributes not given are not checked.

Pass `klass:` to capture only the metric calls made through one class's logger:
`semantic_logger_metrics(klass: Signup) { ... }`.

### RSpec

With `include SemanticLogger::Test::RSpec`, `capture_semantic_logger_metrics` returns the metric
calls made in its block, `be_a_semantic_logger_metric` and `a_semantic_logger_metric` match one of
them, and the block matcher `record_semantic_logger_metric` captures them for you:

~~~ruby
it "counts sign ups" do
  metrics = capture_semantic_logger_metrics { Signup.new.call(user) }
  expect(metrics).to include(a_semantic_logger_metric(name: "users.signup", kind: :counter, value: 1))
  expect(metrics.first).to be_a_semantic_logger_metric(name: "users.signup")
end

it "times the supplier" do
  expect { Signup.new.call(user) }.to(
    record_semantic_logger_metric(name: "supplier.add_user", kind: :histogram, unit: "s")
  )
end
~~~

Pass a class to `capture_semantic_logger_metrics(Signup) { ... }`, or `on: Signup` to
`record_semantic_logger_metric`, to capture only that class's metric calls.

### Without the helpers

Stub a `CaptureLogEvents` in for a class's logger, or for the processor, and read its
`metric_events`. Standing in for the processor, it also keeps in `snapshots` each
`SemanticLogger::Metric::Snapshot` that the collector gives it, as the metric appenders would be
given them:

~~~ruby
capture = SemanticLogger::Test::CaptureLogEvents.new
Signup.stub(:logger, capture) { Signup.new.call(user) }

metric = capture.metric_events.first
assert_equal "users.signup", metric.name
assert_equal :counter, metric.kind
~~~
