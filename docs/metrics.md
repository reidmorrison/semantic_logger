---
layout: default
---

## Metrics

A **metric** is a named number that Semantic Logger emits alongside a log entry, so the same call
that records what happened can also feed your dashboards and alerts. Metrics are useful to track
things like:

* How long a block of code takes to run.
* How often an error, or any other event, occurs.
* Running totals, such as the amount purchased per department over time.

You attach a metric to an ordinary log or `measure_` call by adding the `:metric` option and a name.
Any registered [metric subscriber](#metric-subscribers) (Statsd, New Relic, and so on) is then
notified, asynchronously, on the background log thread. Metrics are subject to the same log level
and filtering as the log entry they ride along with, so a metric on a `:trace` call is not emitted
when the level is `:info`.

There are two kinds of metric: **duration** metrics and **counting** metrics.

### Duration Metrics

Log how long it took to call an external interface and send that duration as a metric to all
metric subscribers.

To set any duration based metric, add the `:metric` option to any `measure_` logging call,
along with a name for the metric:

~~~ruby
logger.measure_info("Called supplier", metric: "supplier/add_user") do
  # Code to call external service ...
end
~~~

Using keyword arguments, add the `:metric` option to any level based logging call,
along with a name for the metric as well as the required `:duration` in ms.

~~~ruby
logger.info(message: "Called supplier", metric: "supplier/add_user", duration: 100.23)
~~~

### Counting Metrics

Counting metrics can be incremented or decremented as part of a logging call.
Using keyword arguments, add the `:metric` option.

~~~ruby
logger.info(message: "Called supplier", metric: "supplier/called_user")
~~~

In the above example the metric `supplier/called_user` is incremented by 1.

To decrement a metric:

~~~ruby
logger.info(message: "Called supplier", metric: "supplier/called_user", metric_amount: -1)
~~~

To increment total counters, such as the total dollar amount of purchases by department:

~~~ruby
logger.info(message: "Purchase complete", metric: "departments/clothing", metric_amount: 189.42)
~~~

Note: Statsd total counters only supports integers, floats are rounded to the nearest integer.

### Metric Subscribers

Subscribers will receive every log message that has a `:metric` option
specified. The subscribers are called asynchronously from the Appender Thread so
as not to impact the original thread that logged the message.

#### Statsd

Send metrics to [Statsd](https://github.com/quasor/statsd) via UDP so it can roll them up and send them to
[graphite](http://graphite.wikidot.com/) or [mongodb](http://mongodb.org).

~~~ruby
SemanticLogger.add_appender(
  metric: :statsd,
  url:    'udp://localhost:8125'
)
~~~

#### New Relic

To forward metrics to New Relic so that they can be displayed using custom dashboards:

~~~ruby
SemanticLogger.add_appender(metric: :new_relic)
~~~

#### Elasticsearch & Splunk

Metrics are sent as part of the log message to Elasticsearch and Splunk so that
they can be displayed using their custom dashboards.

### Notes

**Performance:** Metric subscribers run on the background logging thread, so emitting a metric never
slows down the thread that logged it.

**Log level:** A metric is only emitted when its log entry is actually logged, so it follows the
same log level and filtering rules as any other entry. You can use this to your advantage: keep
detailed `:trace` level metrics in the code where they stay dormant under an `:info` level, then
turn them on when needed, for example by sending the `SIGUSR2` [signal](signals.html) to lower the
log level on a running process.

### [Next: Signals ==>](signals.html)
