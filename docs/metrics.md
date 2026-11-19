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

Supply `:metric_amount` to change the amount. A metric counts upward, so the amount is zero or
more. To count something that goes down, such as items removed from a cart, give it a metric of its
own:

~~~ruby
logger.info(message: "Item removed", metric: "cart/items_removed")
~~~

A negative `:metric_amount` is deprecated: it is still logged and sent as before, but reports a
[deprecation warning](upgrading.html#seeing-deprecation-warnings), and v6 drops it. See
[Negative metric amounts](upgrading.html#negative-metric-amounts).

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
SignalFx) can break it down, for example by region, plan, or status. Add them with the
`:dimensions` option:

~~~ruby
# A counter, broken down by plan:
logger.info(metric: "filters.count", dimensions: {plan: "premium"})

# An amount, broken down by region:
logger.info(metric: "filters.applied", metric_amount: 3, dimensions: {region: "eu-west"})

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

The same holds for the metric name: never build it from an id, as in `"users/#{user.id}/fetch"`.
Statsd and New Relic then record a new metric for every user, and SignalFx turns the parts of the
name into `class` and `action` dimensions, a new time series for every user.

To find what happened to one user, order, or request, log its id in the
[payload](api.html#step-3-add-structured-data) of the entry instead, where a log appender stores
it with that entry rather than as a metric of its own. Named tags are written with the entry too,
except by the `:loki` appender, which makes each named tag a stream label: Loki keeps a stream for
every combination of label values, so an id there has the same effect as an id in a dimension.

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

New Relic charts custom metrics only under `Custom/`, so the subscriber records
`metric: "Orders/placed"` as `Custom/Orders/placed`, and a name that already starts with `Custom/`
as it is. To group an application's metrics, pass a `prefix:` that also starts with `Custom/`:
`prefix: "Custom/MyApp"` records `Orders/placed` as `Custom/MyApp/Orders/placed`. A metric is sent
under its name alone, leaving out its dimensions, since the agent's metric API takes none.

### SignalFx

Forward metrics to [SignalFx](https://www.splunk.com/en_us/products/infrastructure-monitoring.html),
which is built around dimensions:

~~~ruby
SemanticLogger.add_appender(metric: :signalfx, token: "SIGNALFX_ORG_ACCESS_TOKEN")
~~~

`application` and `host` are always sent as dimensions, and so is `environment` when it is set. To
also forward specific named tags as dimensions whenever they are present, and not blank, on a log
entry that has no dimensions of its own, list them:

~~~ruby
SemanticLogger.add_appender(
  metric:     :signalfx,
  token:      "SIGNALFX_ORG_ACCESS_TOKEN",
  dimensions: [:region, :plan]
)
~~~

List only named tags whose values are bounded (see
[Keep the values of each dimension bounded](#keep-the-values-of-each-dimension-bounded)): a named
tag such as a request or user id would make a new metric time series for every request or user.

When a duration metric has no dimensions, SignalFx receives both its value and a count, so you can
chart both the timing and the number of occurrences. The value is the duration and the count is 1,
unless a `metric_amount` is given, which is sent as both. They are sent as `Application.average` and
`Application.counter`, with `class` and `action` dimensions taken from the metric name, such as
`class: "supplier"` and `action: "add_user"` for `supplier/add_user`. A count without dimensions is
sent as `Application.counter` alone, with the same `class` and `action` dimensions.

When dimensions are present, the metric is sent as-is: under its own name, without its leading `/`
characters and with each other `/` replaced by `.`, with its value (the `metric_amount` when given,
otherwise the duration, or 1 for a count), and, for a duration, without a count. Its dimensions are sent in place of the named tags
listed in `dimensions:` above, so add any of those values it needs to its own dimensions.

A dimension whose value is blank, `nil` or text that is empty or only whitespace, is left out, since
it carries nothing to break the metric down by. Dimensions that are empty, such as `{}`, or whose
values are all blank, such as `{state: ""}` or `{supplier: nil}`, count as none, so the metric is
sent as a metric without dimensions is.

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
