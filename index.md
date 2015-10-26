---
layout: default
---

Semantic Logger is a logging infrastructure that supports logging of meta-data, along with text messages
to multiple appenders. Machines can understand the logged data without having to use
complex Regular Expressions or other text parsing techniques.

An appender is a Logging destination such as a File, MongoDB collection, etc..
Multiple Appenders can be active at the same time. Each log entry is written to every appender.

Semantic Logger is as a drop in replacement for existing Ruby loggers, and can also
be used on top of existing logger implementations to extend their capabilities.

Example of current calls:

```ruby
logger.info("Queried users table in #{duration} ms, with a result code of #{result}")
```

For a machine to find all queries for table 'users' that took longer than
100 ms, would require using a regular expression just to extract the table name
and duration, then apply the necessary logic. It also assumes that the text
is not changed and that matches will not be found when another log entry has
similar text output.

This can be changed over time to:

```ruby
logger.info('Queried table',
  duration: duration,
  result:   result,
  table:    'users',
  action:   'query')
```

Using the MongoDB appender, we can easily find all queries for table 'users'
that took longer than 100 ms:

```javascript
db.logs.find({
  "payload.table":"users",
  "payload.action":"query",
  "payload.duration":{$gt:100}
})
```

Since Semantic Logger can call existing Loggers, it does not force end-users
to have to adopt a Semantic aware adapter. Although, such adapters create
tremendous value in the problem monitoring and determination processes.

### Example usage:

```ruby
require 'semantic_logger'

# Set the global default log level
SemanticLogger.default_level = :trace

# Log to a file, and use the colorized formatter
SemanticLogger.add_appender('development.log', &SemanticLogger::Appender::Base.colorized_formatter)

# Create an instance of a logger
# Add the application/class name to every log message
logger = SemanticLogger['MyClass']

# Informational logging
logger.info("Calling Supplier")

# Error information
logger.error("Oops external call failed", :result => :failed, :reason_code => -10)

# Set this thread's name for when multiple threads are all logging at the same time
Thread.current.name = "main"

# Debug information
results = [ 5, 7, 2, 10 ]
logger.debug { "A total of #{results.inject(0) {|sum, i| i+sum }} were processed" }

# New level for logging low level trace information such as data sent or received
raw_response = "<xml><user>jbloggs</user><lastname>Bloggs</lastname><firstname>Joe</firstname></xml>"
logger.trace "Raw data received from Supplier:", raw_response

# Measure and log how long it takes to execute a block of code
logger.benchmark_info "Called external interface" do
  # Code to call external service ...
  sleep 0.75
end

# Add tags to every log entry within the code block
# For example session id, source ip address, username, etc.
logger.tagged('jbloggs') do
  # All log entries in this block will include the tag 'jbloggs'
  logger.info("Hello World")
  logger.debug("More messages")
end
```

### Log file output from the Example above

![development.log](images/example_output.png)

## Features

### High Performance

* Supports logging from hundreds of concurrent threads in the same process.
* Logging is performed in a separate thread so as not to slow down the application
  whilst logging to one or more destinations.

### Drop-in Replacement

* Simple drop-in replacement for the Ruby, or the Rails loggers.
* Supports current common logging interface.
* No changes to existing to code to use new logger ( other than replacing the logger ).

### Dynamic

* Increase the log level at runtime for just one class.
* For example enable debug level logging for a single class (logging instance)
  while the program is running to get more detailed logging in production for just that class.
* Change the default global logging level for all classes, unless that class has
  specifically been overridden above.
* Use UNIX signals to change the log level for a running process.

### Tagged Logging

* Supply custom data to be added to every log entry within a block of code,
  including libraries and existing gems.
* Tagged logging is critical for any high traffic site so that one can narrow
  down log entries for a single call that is mixed in with log entries
  from hundreds of other log entries.

### Payload support

* Aside from the regular log message, a hash payload can also be supplied with
  every log entry.
* Very powerful when logging to NOSQL destinations that allow queries against
  any data in the payload.

### Exceptions

* Directly log exceptions.
* Semantic Logger standardizes the logging of exceptions with their backtraces
  to text destinations and writes the exception elements as a hash to NOSQL
  destinations.

### Benchmarking

* The performance of any block of code can be measured and logged at the same time
  depending on the active log level.
* Supports only logging when the block of code exceeds a specified number of milli-seconds.
  Makes it easy to find bottlenecks when the system suddenly slows down in production.
* Exceptions thrown in the block of code can also be logged so as to aid in finding
  exceptions that may be discarded or hidden by the application.
* Benchmarked data can also be forwarded to external metric systems so that the
  performance of these blocks can be measured and/or monitored over time.

### Thread Safe

* Semantic Logger is completely thread safe and all methods can be called
  concurrently from any thread.
* Tagged logging keeps any tagging data on a per-thread basis to ensure that
  tags from different threads are not inter-mingled.
* Supports highly concurrent environments running hundreds of threads.
* Each appender writes all log entries sequentially in the appender thread so
  that log entries are written in the correct sequence.
* Avoids issues that other loggers experience when multiple threads try to write
  to the same log file at the same time creating partial and overwritten log
  entries in the log file.

### Thread Aware

* Includes the process id, and thread name or thread id in every log entry so that
  log entries from different processes and even threads are easily discernible.
* Human readable names can be assigned to every thread for logging purposes.

### Trace Level

* :trace is a new level common in other languages and is commonly used for
  logging trace level detail. It is intended for logging data at level below
  :debug.
* :trace can be used for logging the actual data sent or received over the network
  that is rarely needed but is critical when things are not working as expected.
* Since :trace can be enabled on a per class basis it can even be turned on
  in production to resolve what was actually sent to an external vendor.

### Multiple Destinations

* Log to multiple destinations at the same time ( File and MongoDB, etc.. )
* Each destination can also have its own log level.
  For example, only log :info and above to MongoDB, or :warn and above to a
  second log file.

### Semantic Capabilities

* With Semantic Logger it is simple to mix-in additional semantic information with
every log entry.
* The application or class name is automatically included for every log entry under
  a specific logging instance.
* Includes the duration of blocks of code.
* Any hash containing context specific information such as user_id or location information.

### Beyond Tagged Logging

* Supply entire hash of custom data to be added to the payload of every log entry
  within a block of code, including libraries and existing gems.

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

* Custom formatting by destination.
* Easy to "roll your own" destination (Appender).
  For example to log to Hadoop, Redis, etc..

## Why Semantic Logger?

Just as there is the initiative to add Semantic information to data on the web
so that computers can directly understand the content without having to resort
to complex regular expressions or machine learning techniques, it is important
to be able to do the same with log files or data.

Semantic Logger allows every log entry to have not only a message, but a payload
that can be written to a file or a NOSQL destination.

Once the logging data is in the NOSQL data store it can be queried quickly and
efficiently. Some SQL data stores also allow complex data types that could be used
for storing and querying the logging data

Before writing SemanticLogger all of the following logging frameworks were thoroughly
evaluated. None of them met the above Semantic requirements, or the performance requirements
of hundreds of threads all logging at the same time:
logback, logging, log4r, central_logger, whoops, etc.

### Performance

The traditional logging implementations write their log information to file in the
same thread of execution as the program itself. This means that for every log entry
the program has to wait for the data to be written.

With Semantic Logger it uses a dedicated thread for logging so that writing to
the log file or other appenders does not hold up program execution.

Also, since the logging is in this separate thread there is no impact to program
execution if we decided to add another appender.
For example, log to both a file and a MongoDB collection.

### Architecture & Performance

In order to ensure that logging does not hinder the performance of the application
all log entries are written to a thread-safe Queue. A separate thread is responsible
for writing the log entries to each of the appenders.

In this way formatting and disk or network write delays will not affect the
performance of the application. Also adding more than one appender does not affect
the runtime performance of the application.

The logging thread is automatically started on initialization. When the program
terminates it will call flush on each of the appenders.

Calling SemanticLogger::Logger#flush will wait until all outstanding log messages
have been written and flushed to their respective appenders before returning.

### [Next: Rails ==>](rails.html)
