---
layout: default
---

## Log Event

When a message is logged, it generates a Log event that is then passed to each of the
appenders, usually on a separate thread so as not to impact processing.

These log events are passed to custom filters, formatters and log appenders.

The Log event object consists of the following attributes:

|Attribute|Type|Description|
|---------|----|-------|
|backtrace|`Array<String>`|The thread backtrace if backtraces are enabled.|
|context|`Hash`|Named contexts that were captured in-line at the point where the log event was created.|
|dimensions|`Hash`|Dimensions supplied during the log call.|
|duration|`Float`|The time taken in milli-seconds to complete a measure call.|
|exception|`Exception`|Ruby Exception object to log.|
|level|`Symbol`|Log level of the supplied log call: `:trace, :debug, :info, :warn, :error, :fatal`|
|level_index|`Integer`|Integer version of level: `:trace=>0, :debug=>1, :info=>2, :warn=>3, :error=>4, :fatal=>5`|
|message|`String`|Text message to be logged.|
|metric|`String`|Metric name to log.|
|metric_amount|`Float`|Metric amount supplied on the log call, if any. Used for numeric or counter metrics. |
|name|`String`|Class name supplied to the logging instance.|
|named_tags|`Hash<String, Object>`|Any named tags active on the thread when the log call was made.|
|payload|`Hash`|Optional Hash object to be logged.|
|tags|`Array<String>`|Any tags active on the thread when the log call was made.|
|thread_name|`String`|Name or id of the thread in which the logging call was called.|
|time|`Time`|The time at which the log entry was created.|

Other helper methods on the log event object:

|Method|Type|Description|
|---------|----|-------|
|backtrace_to_s|`String`|The exception backtrace as a string, including the entire chain of exceptions.|
|cleansed_message|`String`|Strip the standard Rails colorizing from the logged message.|
|duration_human|`String`|The duration in human readable form.|
|duration_to_s|`String`|The duration as a string in milli-seconds.|
|each_exception|Enumerator|Iterate over the chain of exception objects.|
|file_name_and_line(backtrace)|`[String,String]`|The file name and line number from the supplied backtrace.|
|level_to_s|`String`|Single character upper case log level.|
|metric_only?|`true` or `false`|A metric only event has a metric, but no message or exception. For example human readable text logs do not log metric only events, whereas JSON (machine readable) appenders generally would.|
|payload_to_s|`String` or `nil`|The payload in text form, or nil if no payload present.|
|payload?|`true` or `false`|Whether this log event has a payload.|

### [Next: View on Github ==>](https://github.com/reidmorrison/semantic_logger)
