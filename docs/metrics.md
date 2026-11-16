---
layout: default
title: Metrics
description: >-
  Emit named numeric metrics alongside log entries: counters, durations,
  breaking a metric down with dimensions, and sending them on to a metrics
  backend.
---


**Contents**

* TOC
{:toc}

A **metric** is a named number that Semantic Logger emits alongside a log entry, so the same call
that records *what happened* can also feed your dashboards and alerts.

Use metrics to track things like:

* How often an event happens (an error, a sign-up, a cache miss).
* How long something takes (an external API call, a database query).
* Running totals, such as the amount purchased per department over time.

There are two parts to using metrics:

1. **Emit** a metric by adding the `:metric` option to any log or `measure_` call. This is covered in
   Steps 1 to 3 below.
2. **Subscribe** a destination (Statsd, New Relic, SignalFx, and so on) that receives those metrics.
   Until a subscriber is registered, the `:metric` option is harmless: the number reaches no metrics
   backend, though the log appenders that write structured data still write it with the entry. See
   [Send metrics to a backend](#send-metrics-to-a-backend) and
   [Metrics in log appenders](#metrics-in-log-appenders).

Metric subscribers are notified asynchronously on the background log thread, so emitting a metric
never slows the calling thread. A metric rides along with its log entry, so it obeys the same level
and [filtering](config.html#filtering) rules: a metric on a `:trace` call is not emitted while the
level is `:info`.

> **Not to be confused with operational stats.** The metrics on this page are *application* metrics
> that your code emits about what it is doing. To monitor Semantic Logger's *own* health instead,
> such as queue sizes and the number of log entries processed or dropped, use
> [`SemanticLogger.stats`](operations.html#monitoring-the-background-thread).

## Step 1: Count something

The simplest metric counts how often something happens. Add `:metric` with a name to any log call,
and the metric is incremented by 1:

~~~ruby
logger.info(message: "Signed up", metric: "users/signup")
~~~

Supply `:metric_amount` to change the amount. To decrement:

~~~ruby
logger.info(message: "Item removed", metric: "cart/items", metric_amount: -1)
~~~

To add to a running total, such as the dollar amount of purchases per department:

~~~ruby
logger.info(message: "Purchase complete", metric: "departments/clothing", metric_amount: 189.42)
~~~

Note: Statsd counters are integers, so float amounts are rounded to the nearest integer.

## Step 2: Measure how long something takes

A duration metric records elapsed time. The easiest way is to add `:metric` to a `measure_` block
(see [Measure how long something takes](api.html#step-6-measure-how-long-something-takes) in the
Guide). The measured duration becomes the metric:

~~~ruby
logger.measure_info("Called supplier", metric: "supplier/add_user") do
  # Code to call the external service ...
end
~~~

When you already have the duration, emit it on a plain log call by supplying both `:metric` and
`:duration` (in milliseconds):

~~~ruby
logger.info(message: "Called supplier", metric: "supplier/add_user", duration: 100.23)
~~~

## Step 3: Break a metric down with dimensions

Dimensions are key/value labels attached to a metric, so a backend that supports them (such as
SignalFx) can slice it, for example by user, action, or state. Add them with the `:dimensions`
option:

~~~ruby
# A counter, broken down by user:
logger.info(metric: "filters.count", dimensions: {user: "jbloggs"})

# An amount, broken down by user:
logger.info(metric: "filters.applied", metric_amount: 3, dimensions: {user: "jbloggs"})

# A duration, broken down by supplier:
logger.measure_info("Called supplier", metric: "supplier/add_user", dimensions: {supplier: "acme"}) do
  # Code to call the external service ...
end
~~~

Not every subscriber supports dimensions. **Statsd** and **New Relic** record a metric with
dimensions under its name alone, leaving out the dimensions, which their clients do not accept;
**SignalFx** is built around them. See each subscriber below. To keep the metrics with dimensions
out of Statsd or New Relic, for example when they also go to SignalFx, add the subscriber with
`filter: ->(log) { !log.dimensions? }`. The formatters that write structured data also write the
dimensions with the entry, see [Metrics in log appenders](#metrics-in-log-appenders).

## Send metrics to a backend

A metric reaches no metrics backend until a **metric subscriber** is registered. Add one with
`SemanticLogger.add_appender(metric: ...)`, usually when your application starts. A subscriber
receives every logged entry that has a `:metric`, asynchronously on the background thread.

### Statsd

Send metrics to [Statsd](https://github.com/statsd/statsd) over UDP, which can roll them up and
forward them to [Graphite](https://graphiteapp.org), MongoDB, and others (requires the
`statsd-ruby` gem):

~~~ruby
SemanticLogger.add_appender(metric: :statsd, url: "udp://localhost:8125")
~~~

The `url:` must be `udp://`, and its host must resolve when the subscriber is added, or `add_appender`
raises. A path in the url, as in `udp://localhost:8125/my_app`, is the namespace of every metric.

Counters are integers (float amounts are rounded). A metric is sent under its name alone, leaving out
its dimensions, since the `statsd-ruby` client has no tags.

### New Relic

Forward metrics to New Relic so they can be displayed on custom dashboards (requires the
`newrelic_rpm` gem):

~~~ruby
SemanticLogger.add_appender(metric: :new_relic)
~~~

A metric is sent under its name alone, leaving out its dimensions, since the agent's metric API takes
none.

### SignalFx

Forward metrics to [SignalFx](https://www.splunk.com/en_us/products/infrastructure-monitoring.html),
which is built around dimensions:

~~~ruby
SemanticLogger.add_appender(metric: :signalfx, token: "SIGNALFX_ORG_ACCESS_TOKEN")
~~~

`application` and `host` are always sent as dimensions. To also forward specific named tags as
dimensions whenever they are present on a log entry, list them:

~~~ruby
SemanticLogger.add_appender(
  metric:     :signalfx,
  token:      "SIGNALFX_ORG_ACCESS_TOKEN",
  dimensions: [:user_id, :state]
)
~~~

When a duration metric has no dimensions, SignalFx receives both its value and a count, so you can
chart both the timing and the number of occurrences. The value is the duration and the count is 1,
unless a `metric_amount` is given, which is sent as both. When dimensions are present, the metric is
sent as-is: under its own name, with each `/` replaced by `.`, and a duration without a count.

## Metrics in log appenders

Metric subscribers are the destinations for metrics. Log [appenders](appenders.html) treat a metric
as part of the log entry that carries it:

* **A metric on an entry with a message or an exception** is written with the entry by the
  formatters that write structured data, so a log store such as Elasticsearch or Splunk can chart
  it without a metric subscriber. The text formatters do not write it; they show only the
  entry's duration.
* **A metric-only entry**, one with a metric but no message and no exception, such as
  `logger.info(metric: "users/signup")`, is meant for the metric subscribers. There can be many
  such entries, so log appenders leave them out, unless one is added with `metrics: true`:

  ~~~ruby
  # Also index metric-only entries in Elasticsearch:
  SemanticLogger.add_appender(appender: :elasticsearch, url: "http://localhost:9200", metrics: true)
  ~~~

  Until v6, the `:kafka`, `:rabbitmq`, and `:udp` appenders send them by default, and report a
  [deprecation warning](upgrading.html#seeing-deprecation-warnings) when they are added without
  `metrics:`. Pass `metrics: false` to leave them out, as v6 does by default, or `metrics: true` to
  keep sending them.

What each formatter writes for a metric on an entry with a message:

| Formatter | Metric fields written |
|-----------|-----------------------|
| `:json`, `:raw`, `:fluentd`, `:syslog_cee`, `:new_relic_logs` | `metric`, `metric_amount`, and `dimensions` |
| `:ecs` | `metric`, `metric_amount`, and `dimensions`, under its namespace, `semantic_logger` by default, or in `labels` when it has none |
| `:loki` | `metric`, `metric_value`, and `dimensions` (as JSON), in the structured metadata |
| `:open_telemetry` | The `semantic_logger.metric` and `semantic_logger.metric_amount` attributes, and a `semantic_logger.dimensions.<key>` attribute for each dimension |
| `:default`, `:color`, `:one_line`, `:pattern`, `:syslog`, `:logfmt` | None; only the duration is shown |

An appender writes what its formatter writes. For example `:elasticsearch`, `:opensearch`,
`:splunk_http`, `:mongodb`, and `:graylog` use `:raw` by default, and `:http`, `:tcp`, `:udp`,
`:kafka`, `:rabbitmq`, and `:cloudwatch_logs` use `:json`.

## How metrics behave

**Asynchronous.** Subscribers run on the background logging thread, so emitting a metric never slows
down the thread that logged it.

**Follows the log level.** A metric is emitted only when its log entry is actually logged, so it
obeys the same log level and filtering as any other entry. Use this to your advantage: leave detailed
`:trace` level metrics in the code where they stay dormant under an `:info` level, then turn them on
when needed, for example by sending the `SIGUSR2` [signal](operations.html#linux-signals) to lower
the log level on a running process.
