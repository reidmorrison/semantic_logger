---
layout: default
---

## Metrics

When logging data it is also useful to gather metrics that can be used in dashboards to track:

* Duration of blocks of code.
* Quantity of each error or any other count.
* Total amount of purchases by department over time.
* etc...

### Duration Metrics

Log how long it took to call an external interface and send that duration as a metric to all
metric subscribers.

To set any duration based metric, add `:metric` option to any `measure_` logging call,
along with a name for the metric:

~~~ruby
logger.measure_info('Called supplier', metric: 'supplier/add_user') do
  # Code to call external service ...
end
~~~

Using keyword arguments, add the `:metric` option to any level based logging call,
along with a name for the metric as well as the required `:duration` in ms.

~~~ruby
logger.info(message: 'Called supplier', metric: 'supplier/add_user', duration: 100.23)
~~~

### Counting Metrics

Counting metrics can be incremented or decremented as part of a logging call.
Using keyword arguments, add the `:metric` option.

~~~ruby
logger.info(message: 'Called supplier', metric: 'supplier/called_user')
~~~

In the above example the metric `supplier/called_user` is incremented by 1.

To decrement a metric:

~~~ruby
logger.info(message: 'Called supplier', metric: 'supplier/called_user', metric_amount: -1)
~~~

To increment total counters, such as the total dollar amount of purchases by department:

~~~ruby
logger.info(message: 'Purchase complete', metric: 'departments/clothing', metric_amount: 189.42)
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
subscriber = SemanticLogger::Metrics::Statsd.new(url: 'udp://localhost:8125')
SemanticLogger.on_log(subscriber)
~~~

#### New Relic

To forward metrics to New Relic so that they can be displayed using custom dashboards:

~~~ruby
subscriber = SemanticLogger::Metrics::NewRelic.new
SemanticLogger.on_log(subscriber)
~~~

#### Elasticsearch & Splunk

Metrics are sent as part of the log message to Elasticsearch and Splunk so that
they can be displayed using their custom dashboards.

#### Custom Subscriber

For example, if running a rails application, create a file called `config/initializers/semantic_logger_metrics.rb`

~~~ruby
SemanticLogger.on_log do |log_struct|
  puts "Metric: #{log_struct.metric} with duration: #{log_struct.duration}ms"
end
~~~

For the format of the `Log Struct`, see [Log Struct](log_struct.html)

### Notes

Performance

* All metrics all called in the separate logging thread so as not to impact the thread that created
the metric.

Log level

* Metrics are only forwarded for log messages that are not filtered out or do not exceed or meet the current log level.
* For example, use `:trace` level metrics during testing that are not visible when the log level is `:info`.
* For example, `:trace` metrics can be turned on again by sending the `-SIGUSR2` [signal](signals.html) to the process to change the log level.

### [Next: Signals ==>](signals.html)
