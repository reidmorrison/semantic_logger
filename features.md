---
layout: default
---

## Features

The features of Semantic Logger and why it should be considered over existing
Logging solutions:

### High Performance

* Logging is performed in a separate thread so as not to slow down the application
  whilst logging to one or more destinations
* Supports logging from hundreds of concurrent threads in the same process

### Drop-in Replacement

* Simple drop-in replacement for the Ruby, or the Rails loggers
* Supports current common logging interface
* No changes to existing to code to use new logger ( other than replacing the logger )

### Dynamic

* Increase the log level at runtime for just one class
* For example enable debug level logging for a single class (logging instance)
  while the program is running to get more detailed logging in production for just that class
* Change the default global logging level for all classes, unless that class has
  specifically been overridden above
* Use UNIX signals to change the log level for a running process

### Tagged Logging

* Supply custom data to be added to every log entry within a block of code,
  including libraries and existing gems
* Tagged logging is critical for any high traffic site so that one can narrow
  down log entries for a single call that is mixed in with log entries
  from hundreds of other log entries

### Payload support

* Aside from the regular log message, a hash payload can also be supplied with
  every log entry
* Very powerful when logging to NOSQL destinations that allow queries against
  any data in the payload

### Exceptions

* Directly log exceptions
* Semantic Logger standardizes the logging of exceptions with their backtraces
  to text destinations and writes the exception elements as a hash to NOSQL
  destinations

### Benchmarking

* The performance of any block of code can be measured and logged at the same time
  depending on the active log level
* Supports only logging when the block of code exceeds a specified number of milli-seconds.
  Makes it easy to find bottlenecks when the system suddenly slows down in production
* Exceptions thrown in the block of code can also be logged so as to aid in finding
  exceptions that may be discarded or hidden by the application
* Benchmarked data can also be forwarded to external metric systems so that the
  performance of these blocks can be measured and/or monitored over time

### Thread Safe

* Semantic Logger is completely thread safe and all methods can be called
  concurrently from any thread
* Tagged logging keeps any tagging data on a per-thread basis to ensure that
  tags from different threads are not inter-mingled
* Supports highly concurrent environments running hundreds of threads
* Each appender writes all log entries sequentially in the appender thread so
  that log entries are written in the correct sequence
* Avoids issues that other loggers experience when multiple threads try to write
  to the same log file at the same time creating partial and overwritten log
  entries in the log file

### Thread Aware

* Includes the process id, and thread name or thread id in every log entry so that
  log entries from different processes and even threads are easily discernable
* Human readable names can be assigned to every thread for logging purposes

### Trace Level

* :trace is a new level common in other languages and is commonly used for
  logging trace level detail. It is intended for logging data at level below
  :debug.
* :trace can be used for logging the actual data sent or received over the network
  that is rarely needed but is critical when things are not working as expected.
* Since :trace can be enabled on a per class basis it can even be turned on
  in production to resolve what was actually sent to an external vendor

### Multiple Destinations

* Log to multiple destinations at the same time ( File and MongoDB, etc.. )
* Each destination can also have its own log level.
  For example, only log :info and above to MongoDB, or :warn and above to a
  second log file

### Semantic Capabilities

* With Semantic Logger it is simple to mix-in additional semantic information with
every log entry
* The application or class name is automatically included for every log entry under
  a specific logging instance
* Includes the duration of blocks of code
* Any hash containing context specific information such as user_id or location information

### Beyond Tagged Logging

* Supply entire hash of custom data to be added to the payload of every log entry
  within a block of code, including libraries and existing gems

### NOSQL Destinations

* Every log entry is broken down into elements that NOSQL data stores can understand:

```json
{
    "_id" : ObjectId("5034fa48e3f3fea945e83ef2"),
    "time" : ISODate("2012-08-22T15:27:04.409Z"),
    "host_name" : "release",
    "pid" : 16112,
    "thread_name" : "main",
    "name" : "UserLocator",
    "level" : "debug",
    "message" : "Fetch user information",
    "duration" : 12,
    "payload" : {
        "user" : "Jack",
        "zip_code" : 12345,
        "location" : "US"
    }
}
```

### Customizable

* Custom formatting by destination
* Easy to "roll your own" destination (Appender).
  For example to log to Hadoop, Redis, etc..
