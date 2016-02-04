---
layout: default
---

## Log Struct

Internally all log messages are passed around in a Log Struct. In order
to write your own custom formatter or log appender it is necessary to understand
the fields:

~~~ruby
Log = Struct.new(
  :level,
  :thread_name,
  :name,
  :message,
  :payload,
  :time,
  :duration,
  :tags,
  :level_index,
  :exception,
  :metric)
~~~

level [Symbol]

* Log level of the supplied log call
* :trace, :debug, :info, :warn, :error, :fatal

thread_name [String]

* Name or id of the thread in which the logging call was called

name [String]

* Class name supplied to the logging instance

message [String]

* Text message to be logged

payload [Hash\|Exception]

* Optional Hash or Ruby Exception object to be logged

time [Time]

* The time at which the log entry was created

duration [Float]

* The time taken in milli-seconds to complete a benchmark call

tags [Array<String>]

* Any tags active on the thread when the log call was made

level_index [Integer]

* Internal use only. Index of the log level

exception [Object]

* Ruby Exception object to log

metric [Object]

* Object supplied when the benchmark api was called

### [Next: View on Github ==>](https://github.com/rocketjob/semantic_logger)
