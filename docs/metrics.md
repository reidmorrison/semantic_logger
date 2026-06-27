---
layout: default
---

## Metrics
{:.no_toc}

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
   Until a subscriber is registered, the `:metric` option is harmless and the number goes nowhere.
   See [Send metrics to a backend](#send-metrics-to-a-backend).

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

# A gauge with an amount and dimensions:
logger.info(metric: "filters.average", metric_amount: 1.2, dimensions: {user: "jbloggs"})
~~~

Not every backend supports dimensions. **Statsd** and **New Relic** ignore any metric that carries
dimensions; **SignalFx** is built around them. See each subscriber below.

## Send metrics to a backend

A metric goes nowhere until a **metric subscriber** is registered. Add one with
`SemanticLogger.add_appender(metric: ...)`, usually when your application starts. A subscriber
receives every logged entry that has a `:metric`, asynchronously on the background thread.

### Statsd

Send metrics to [Statsd](https://github.com/statsd/statsd) over UDP, which can roll them up and
forward them to [Graphite](https://graphiteapp.org), MongoDB, and others:

~~~ruby
SemanticLogger.add_appender(metric: :statsd, url: "udp://localhost:8125")
~~~

Counters are integers (float amounts are rounded). Does not support dimensions.

### New Relic

Forward metrics to New Relic so they can be displayed on custom dashboards:

~~~ruby
SemanticLogger.add_appender(metric: :new_relic)
~~~

Does not support dimensions.

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

When a duration metric has no dimensions, SignalFx receives both a gauge and a counter, so you can
chart both the timing and the number of occurrences. When dimensions are present, the metric is sent
as-is.

### Elasticsearch and Splunk

These are ordinary log [appenders](appenders.html), not metric subscribers, but a metric is part of
the log entry, so `metric`, `metric_amount`, and any dimensions are written into the document
automatically. You can build dashboards on those fields directly, without registering a separate
metric subscriber.

## How metrics behave

**Asynchronous.** Subscribers run on the background logging thread, so emitting a metric never slows
down the thread that logged it.

**Follows the log level.** A metric is emitted only when its log entry is actually logged, so it
obeys the same log level and filtering as any other entry. Use this to your advantage: leave detailed
`:trace` level metrics in the code where they stay dormant under an `:info` level, then turn them on
when needed, for example by sending the `SIGUSR2` [signal](operations.html#linux-signals) to lower
the log level on a running process.
