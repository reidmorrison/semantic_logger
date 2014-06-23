semantic_logger [![Build Status](https://secure.travis-ci.org/reidmorrison/semantic_logger.png?branch=master)](http://travis-ci.org/reidmorrison/semantic_logger)
===============

Next generation logging system for Ruby to support highly concurrent, high throughput, low latency systems

* http://github.com/reidmorrison/semantic_logger

## Overview

Semantic Logger takes logging in Ruby to the next level by adding several new
capabilities to the commonly used Logging API:

High Performance

* Logging is performed in a separate thread so as not to slow down the application
  whilst logging to one or more destinations
* Supports logging from hundreds of concurrent threads in the same process

Drop-in Replacement

* Simple drop-in replacement for the Ruby, or the Rails loggers
* Supports current common logging interface
* No changes to existing to code to use new logger ( other than replacing the logger )

Dynamic

* Increase the log level at runtime for just one class
* For example enable debug level logging for a single class (logging instance)
  while the program is running to get more detailed logging in production for just that class
* Change the default global logging level for all classes, unless that class has
  specifically been overridden above
* Use UNIX signals to change the log level for a running process

Tagged Logging

* Supply custom data to be added to every log entry within a block of code,
  including libraries and existing gems
* Tagged logging is critical for any high traffic site so that one can narrow
  down log entries for a single call that is mixed in with log entries
  from hundreds of other log entries

Payload support

* Aside from the regular log message, a hash payload can also be supplied with
  every log entry
* Very powerful when logging to NOSQL destinations that allow queries against
  any data in the payload

Exceptions

* Directly log exceptions
* Semantic Logger standardizes the logging of exceptions with their backtraces
  to text destinations and writes the exception elements as a hash to NOSQL
  destinations

Benchmarking

* The performance of any block of code can be measured and logged at the same time
  depending on the active log level
* Supports only logging when the block of code exceeds a specified number of milli-seconds.
  Makes it easy to find bottlenecks when the system suddenly slows down in production
* Exceptions thrown in the block of code can also be logged so as to aid in finding
  exceptions that may be discarded or hidden by the application
* Benchmarked data can also be forwarded to external metric systems so that the
  performance of these blocks can be measured and/or monitored over time

Thread Safe

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

Thread Aware

* Includes the process id, and thread name or thread id in every log entry so that
  log entries from different processes and even threads are easily discernable
* Human readable names can be assigned to every thread for logging purposes

Trace Level

* :trace is a new level common in other languages and is commonly used for
  logging trace level detail. It is intended for logging data at level below
  :debug.
* :trace can be used for logging the actual data sent or received over the network
  that is rarely needed but is critical when things are not working as expected.
* Since :trace can be enabled on a per class basis it can even be turned on
  in production to resolve what was actually sent to an external vendor

Multiple Destinations

* Log to multiple destinations at the same time ( File and MongoDB, etc.. )
* Each destination can also have its own log level.
  For example, only log :info and above to MongoDB, or :warn and above to a
  second log file

Semantic Capabilities

* With Semantic Logger it is simple to mix-in additional semantic information with
every log entry
* The application or class name is automatically included for every log entry under
  a specific logging instance
* Includes the duration of blocks of code
* Any hash containing context specific information such as user_id or location information

Beyond Tagged Logging

* Supply entire hash of custom data to be added to the payload of every log entry
  within a block of code, including libraries and existing gems

NOSQL Destinations

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

Customizable

* Custom formatting by destination
* Easy to "roll your own" destination (Appender).
  For example to log to Hadoop, Redis, etc..

## Introduction

Semantic Logger is a Logger that supports logging of meta-data, along with text messages
to multiple appenders

An appender is a Logging destination such as a File, MongoDB collection, etc..
Multiple Appenders can be active at the same time. All log entries are written
to each appender.

Machines can understand the logged data without having to use
complex Regular Expressions or other text parsing techniques

Semantic Logger, sits on top of existing logger implementations and can also
be used as a drop in replacement for existing Ruby loggers.
This allows the existing logging to be replaced immediately with the
Semantic Logger Appenders, and over time the calls can be replaced with ones
that contain the necessary meta-data.

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
logger.info("Queried table",
  :duration => duration,
  :result   => result,
  :table    => "users",
  :action   => "query")
```

Using the MongoDB appender, we can easily find all queries for table 'users'
that took longer than 100 ms:

```javascript
db.logs.find({"payload.table":"users", "payload.action":"query", "payload.duration":{$gt:100} })
```

Since Semantic Logger can call existing Loggers, it does not force end-users
to have to adopt a Semantic aware adapter. Although, such adapters create
tremendous value in the problem monitoring and determination processes.

## Logging API

### Standard Logging methods

The Semantic Logger logging API supports the existing logging interface for
the Rails and Ruby Loggers. For example:

```ruby
logger.info("Hello World")
```

Or to query whether a specific log level is set

```ruby
logger.info?
```

The following traditional logging methods are available

```ruby
logger.trace("Low level trace information such as data sent over a socket")
logger.debug("Debugging information to aid with problem determination")
logger.info("Informational message such as request received")
logger.warn("Warn about something in the system")
logger.error("An error occurred during processing")
logger.fatal("Oh no something really bad happened")
```

Each of the above calls can take additional parameters, for example:

```ruby
log.info(message, payload=nil, exception=nil, &block)
```

Parameters

- message:   The text message to log.
  Mandatory only if no block is supplied
- payload:   Optional, either a Ruby Exception object or a Hash
- exception: Optional, Ruby Exception object. Allows both an exception and a payload to be logged
- block:     The optional block is executed only if the corresponding log level
  is active. Can be used to prevent unnecessary calculations of debug data in
  production.

Examples:

```ruby
logger.debug("Calling Supplier")

logger.debug("Calling Supplier", :request => 'update', :user => 'Jack')

logger.debug { "A total of #{result.inject(0) {|sum, i| i+sum }} were processed" }
```

## Exceptions

The Semantic Logger adds an optional parameter to the existing log methods so that
a corresponding Exception can be logged in a standard way

```ruby
begin
  # ... Code that can raise an exception
rescue Exception => exception
  logger.error("Oops external call failed", exception)
  # Re-raise or handle the exception
  raise exception
end
```

### Payload

The Semantic Logger adds an extra parameter to the existing log methods so that
additional payload can be logged, such as a Hash or a Ruby Exception object.

```ruby
logger.info("Oops external call failed", :result => :failed, :reason_code => -10)
```

The additional payload is machine readable so that we don't have to write complex
regular expressions so that a program can analyze log output. With the MongoDB
appender the payload is written directly to MongoDB as part of the document and
is therefore fully searchable

### Benchmarking

Another common logging requirement is to measure the time it takes to execute a block
of code based on the log level. For example:

```ruby
Rails.logger.benchmark_info "Calling external interface" do
  # Code to call external service ...
end
```

The following output will be written to file:

    2012-08-30 15:37:29.474 I [48308:ScriptThreadProcess: script/rails] (5.2ms) Rails -- Calling external interface

If an exception is raised during the block the exception is logged
at the same log level as the benchmark along with the duration and message.
The exception will flow through to the caller unchanged

The following benchmarking methods are available

```ruby
logger.benchmark_trace("Low level trace information such as data sent over a socket")
logger.benchmark_debug("Debugging information to aid with problem determination")
logger.benchmark_info("Informational message such as request received")
logger.benchmark_warn("Warn about something in the system")
logger.benchmark_error("An error occurred during processing")
logger.benchmark_fatal("Oh no something really bad happened")
logger.benchmark(:info, "Informational message such as request received")
```

Each of the above calls can take additional parameters, for example:

```ruby
log.benchmark_info(message, params=nil) do
  # Measure how long it takes to run this block of code
end
```

Parameters

- message: The mandatory text message to log.
- params:
```
  :log_exception
    Control whether or how an exception thrown in the block is
    reported by Semantic Logger. Values:
    :full
      Log the exception class, message, and backtrace
    :partial
      Log the exception class and message
      The backtrace will not be logged
    :off
      Any unhandled exception raised in the block will not be logged
    Default: :partial

  :min_duration [Float]
    Only log if the block takes longer than this duration in ms
    Default: 0.0

  :payload [Hash]
    Optional, Hash payload

  :exception [Exception]
    Optional, Ruby Exception object to log along with the duration of the supplied block

  :duration [Float]
    Optional, supply the duration in ms that is logged when a block is not supplied
    If a block is not supplied then :duration is mandatory
    If a block is supplied :duration is ignored

  :metric [Object]
    Optional, when this parameter is supplied all subscribers will be notified of this
    metric, along with the Log Struct described below
```

### Logging levels

The following logging levels are available through Semantic Logger

    :trace, :debug, :info, :warn, :error, :fatal

The log levels are listed above in the order of precedence with the most detail to the least.
For example :debug would include :info, :warn, :error, :fatal levels but not :trace
And :fatal would only log :fatal error messages and nothing else

:unknown has been mapped to :fatal for Rails and Ruby Logger

:trace is a new level that is often used for tracing low level calls such
as the data sent or received to external web services. It is also commonly used
in the development environment for low level trace logging of methods calls etc.

If only the rails logger is being used, then :trace level calls will be logged
as debug calls only if the log level is set to trace

### Changing the Class name for Log Entries

When Semantic Logger is included in a Rails project it automatically replaces the
loggers for Rails, ActiveRecord::Base, ActionController::Base, and ActiveResource::Base
with wrappers that set their Class name. For example in semantic_logger/railtie.rb:

```ruby
ActiveRecord::Base.logger = SemanticLogger[ActiveRecord]
```

By replacing their loggers we now get the class name in the text logging output:

    2012-08-30 15:24:13.439 D [47900:main] ActiveRecord --   SQL (12.0ms)  SELECT `schema_migrations`.`version` FROM `schema_migrations`

It is recommended to include a class specific logger for all major classes that will
be logging using the SemanticLogger::Loggable mix-in. For Example:

```ruby
class ExternalSupplier
  # Lazy load logger class variable on first use
  include SemanticLogger::Loggable

  def call_supplier(amount, name)
    logger.debug "Calculating with amount", { :amount => amount, :name => name }

    # Measure and log on completion how long the call took to the external supplier
    logger.benchmark_info "Calling external interface" do
      # Code to call the external supplier ...
    end
  end
end
```

This will result in the log output identifying the log entry as from the ExternalSupplier class

    2012-08-30 15:37:29.474 I [48308:ScriptThreadProcess: script/rails] (5.2ms) ExternalSupplier -- Calling external interface

### Changing the log level for a single class at runtime

Since the logger is class specific, its log level can be changed dynamically at runtime.
For example, to temporarily set the log level to :trace to diagnose an issue:

```ruby
require 'semantic_logger'

SemanticLogger.default_level = :info
SemanticLogger.add_appender('example.log')

class ExternalSupplier
  # Lazy load logger class variable on first use
  include SemanticLogger::Loggable

  def call_supplier(amount, name)
    logger.trace "Calculating with amount", { :amount => amount, :name => name }

    # Measure and log on completion how long the call took to the external supplier
    logger.benchmark_info "Calling external interface" do
      # Code to call the external supplier ...
    end
  end
end

# Create and use the class
supplier = ExternalSupplier.new
supplier.call_supplier(100, 'Jack')

# Now change the log level to :trace
ExternalSupplier.logger.level = :trace

# Call the supplier, this time including trace level messages
supplier.call_supplier(100, 'Jack')

# Change the log level back to the default level
ExternalSupplier.logger.level = SemanticLogger.default_level
```

Below is the output from the above example showing the :trace log level message
that was written during the second call to the ExternalSupplier:

```
2013-11-07 16:19:26.496 I [35674:main] (0.0ms) ExternalSupplier -- Calling external interface

2013-11-07 16:19:26.683 T [35674:main] ExternalSupplier -- Calculating with amount -- {:amount=>100, :name=>"Jack"}
2013-11-07 16:19:26.683 I [35674:main] (0.0ms) ExternalSupplier -- Calling external interface
```

### Change the global default logging level at runtime

Log levels can be changed using signals on operating systems that support them.
This allows log levels to be changed externally without requiring a restart
of the running process.

When the signal is raised, the global default log level rotates through the following
log levels in the following order, starting from the current global default level:

```ruby
  :warn, :info, :debug, :trace
```

If the current level is :trace it wraps around back to :warn

Example (where the target ruby process id is 1234):

```
kill -SIGUSR2 1234
```

#### Enabling Log Level Signal handler

On startup SemanticLogger does not register any signals so that it does not
interfere with any existing signal handlers. In order to enable the above log level
changes the signal handler must be registered by calling `SemanticLogger.add_signal_handler`

```ruby
require 'semantic_logger'

# Enable signal handling for this process
SemanticLogger.add_signal_handler('USR2')

SemanticLogger.add_appender('development.log')

logger = SemanticLogger['Example']
logger.info "Hello World"
```

Note: The changes to the logging level will not change for any classes where the
level was set explicitly within the application itself. The above signal only changes
the global default level, which is used by loggers when their log level has not been changed.

#### Change the log level without using signals

If the application has another means of communicating without needing signals,
the global default log level can be modified using `SemanticLogger.default_level=`

```ruby
# Change the global default logging level for active loggers
SemanticLogger.default_level = :debug
```

### Tagged Logging

Semantic Logger allows any Ruby or Rails program to also include tagged logging.

This means that any logging performed within a block, including any called
libraries or gems to include the specified tag with every log entry.

Using Tagged logging is critical in any highly concurrent environment so that
one can quickly find all related log entries across all levels of code, and even
across threads

```ruby
logger.tagged(tracking_number) do
  logger.debug("Hello World")
  # ...
end
```

### Beyond Tagged Logging

Blocks of code can be tagged with not only values, but can be tagged with
entire hashes of data. The additional hash of data will be merged into
the payload of every log entry

For example every corresponding log entry could include a hash containing
a user_id, name, region, zip_code, tracking_number, etc...

```ruby
logger.with_payload(:user => 'Jack', :zip_code => 12345) do
  logger.debug("Hello World")
  # ...
end
```

### Named threads

SemanticLogger logs the name or id of the thread in every log message.

On Ruby MRI the thread name is by default the thread's object_id, For example: 70184354571980

```
2013-11-07 16:25:14.279627 I [35841:70184354571980] (0.0ms) ExternalSupplier -- Calling external interface
```

To set a custom name for any thread so that it shows up in the logger:

```ruby
Thread.current.name = "User calculation thread 32"
```

Sample output:

```
2013-11-07 16:26:02.744139 I [35841:User calculation thread 32] (0.0ms) ExternalSupplier -- Calling external interface
```

When running JRuby, Thread.current.name will also set the underlying thread name in the JVM
which is very useful when monitoring the JVM via JMX using tools such as jconsole.

#### NOTE:

Make sure that the assigned thread name is unique otherwise it will be difficult
to distinguish between concurrently running threads if they have the same name.

For example, use the current thread object_id to ensure uniqueness:

```ruby
Thread.current.name = "Worker Thread:#{Thread.current.object_id}"
```

### Metrics integration

In production environments it is often necessary to not only measure the performance of a
block of code using for example:

```ruby
logger.benchmark_info "Calling external interface" do
  # Code to call the external supplier ...
end
```

A single subscriber can be defined to collect all the metrics and forward them
for example to NewRelic:

```ruby
# config/initializers/semantic_logger_metrics.rb
SemanticLogger.on_metric do |log_struct|
  ::NewRelic::Agent.record_metric(log_struct.metric, log_struct.duration)
end
```

Add the :metric option to the log entry as follows:

```ruby
logger.benchmark_info "Calling external interface", :metric => 'Custom/slow_action/beginning_work' do
  # Code to call the external supplier ...
end
```

## Standalone SemanticLogger

When using SemanticLogger inside of Rails all we need to do is include the
rails_semantic_logger gem and the default Rails logger will be replaced with
Semantic Logger.

In a stand-alone or non-rails environment we can easily log to a file called
'development.log' as follows:
```ruby
require 'semantic_logger'
SemanticLogger.add_appender('development.log')

logger = SemanticLogger['Example']
logger.info "Hello World"
```

By default it will only log :info and above, to log everything to the log file:
```ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace
SemanticLogger.add_appender('development.log')

logger = SemanticLogger['Example']
logger.info "Hello World"
logger.trace "Low level trace information"
```

By supplying multiple appenders Semantic Logger can write to multiple destinations
at the same time. For example, log to a file and the screen:
```ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace
SemanticLogger.add_appender('development.log')
SemanticLogger.add_appender(STDOUT)

logger = SemanticLogger['Example']
logger.info "Hello World"
logger.trace "Low level trace information"
```

To reduce the log level of logging to STDOUT to just :info and above, add the
level such as :info as the second parameter when adding the appender:
```ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace
SemanticLogger.add_appender('development.log')
SemanticLogger.add_appender(STDOUT, :info)

logger = SemanticLogger['Example']
logger.info "Hello World"
logger.trace "Low level trace information"
```

To log :debug and above to a log file, :error and above to $stderr, and :info
and above to MongoDB:
```ruby
require 'semantic_logger'
require 'mongo'

SemanticLogger.default_level = :debug
SemanticLogger.add_appender('development.log')
SemanticLogger.add_appender($stderr, :error)

mongo_appender = SemanticLogger::Appender::MongoDB.new(
  :db              => Mongodb::Connection.new['production_logging'],
  :collection_size => 25.gigabytes
)
SemanticLogger.add_appender(mongo_appender, :info)

logger = SemanticLogger['Example']
logger.info "Hello World"
logger.trace "Low level trace information"
logger.error "Oops an error occurred"
logger.info("Login time", :user => 'Mary', :duration => 230, :ip_address=>'192.168.0.1')
```

When starting out with Semantic Logger it can be useful to gain all the benefits
of Semantic Logger and still continue to log to an existing logger:
```ruby
require 'logger'
require 'semantic_logger'

# Built-in Ruby logger
log = Logger.new(STDOUT)
log.level = Logger::DEBUG

SemanticLogger.default_level = :debug
SemanticLogger.add_appender(log)

logger = SemanticLogger['Example']
logger.info "Hello World"
logger.debug("Login time", :user => 'Joe', :duration => 100, :ip_address=>'127.0.0.1')
```

It is recommended that every class or module have it's own logging instance.
This can be achieved by including SemanticLogger::Loggable:
```ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace
SemanticLogger.add_appender('development.log')

class ExternalSupplier
  # Makes available a class and instance level logger
  #    ExternalSupplier.logger and ExternalSupplier#logger
  include SemanticLogger::Loggable

  # logger class method example
  def self.hostname=(hostname)
    logger.debug "Setting hostname to #{hostname}"
    @@hostname = hostname
  end

  # logger instance method example
  def call_supplier(amount, name)
    logger.debug "Calculating with amount", { :amount => amount, :name => name }

    # Measure and log on completion how long the call took to the external supplier
    logger.benchmark_info "Calling external interface" do
      # Code to call the external supplier ...
    end
  end
end
```

### Logging to Syslog

Log to a local Syslog:
```ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace
SemanticLogger.add_appender(SemanticLogger::Appender::Syslog.new)
```

Log to a local file and to a remote Syslog server such as syslog-ng over TCP:
```ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace
SemanticLogger.add_appender('development.log')
SemanticLogger.add_appender(SemanticLogger::Appender::Syslog.new(:server => 'tcp://myloghost:514'))
```

### Send errors to New Relic

Adding the New Relic appender will send :error and :fatal log entries to New Relic as error events.
Note: Payload information is not filtered, so take care not to push any sensitive information when logging with tags or a payload.

For a Rails application already configured to use SemanticLogger and New Relic, create a file called <Rails Root>/config/initializers/newrelic_appender.rb with the following contents and restart the application:

```ruby
# Send :error and :fatal log messages to New Relic
SemanticLogger.add_appender(SemanticLogger::Appender::NewRelic.new)
Rails.logger.info 'SemanticLogger New Relic Appender added.'
```

For a non-Rails application, send :info and more severe log entries to a file called application.log and also send :error and :fatal log entries to New Relic.

```ruby
# ./newrelic.yml needs to be set up -- see https://docs.newrelic.com/docs/ruby/ruby-agent-installation for more information.

require 'semantic_logger'
require 'newrelic_rpm'

# New Relic setup
NewRelic::Agent.manual_start

# SemanticLogger setup
SemanticLogger.default_level = :info
SemanticLogger.add_appender('application.log')
SemanticLogger.add_appender(SemanticLogger::Appender::NewRelic.new)
logger = SemanticLogger['Example']

# Log some messages
logger.info  'This is only written to application.log'
logger.error 'This is written to application.log and will also be sent to New Relic as an error event'

# The appender will send tags, payloads and benchmark duration to New Relic
logger.tagged('test') do
  logger.with_payload( {key1: 123, key2: 'abc'} ) do
    logger.benchmark_error(@message) do
      sleep 0.001
    end
  end
end

# New Relic does not seem to receive any errors if the application exits too soon after sending error alerts.
sleep 10

# New Relic shutdown - should send any queued data before exiting
::NewRelic::Agent.shutdown
```

## Configuration

The Semantic Logger follows the principle where multiple appenders can be active
at the same time. For example, this allows one to log to MongoDB and the Rails
log file at the same time.

### Rails Configuration

To automatically replace the Rails logger with Semantic Logger use the gem [rails_semantic_logger](http://github.com/reidmorrison/rails_semantic_logger)

## Log Struct

Internally all log messages are passed around in a Log Struct. In order
to write your own custom formatter or log appender it is necessary to understand
the fields:

```ruby
Log = Struct.new(:level, :thread_name, :name, :message, :payload, :time, :duration, :tags, :level_index, :exception, :metric)
```
level [Symbol]

* Log level of the supplied log call
* :trace, :debug, :info, :warn, :error, :fatal

thread_name [String]

* Name or id of the thread in which the logging call was called

name [String]

* Class name supplied to the logging instance

message [String]

* Text message to be logged

payload [Hash|Exception]

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

### Mixing Logging Levels

It is sometimes useful to log a subset of the log messages to a separate file
or appender. For example, log :error and :fatal level messages to a special
error file.

Below is a stand-alone example that better shows this behavior:

```ruby
require 'semantic_logger'

# Set default log level for new logger instances
SemanticLogger.default_level = :info

# Log all warning messages and above to warnings.log
SemanticLogger.add_appender('log/warnings.log', :warn)

# Log all trace messages and above to trace.log
SemanticLogger.add_appender('log/trace.log', :trace)

logger = SemanticLogger['MyClass']
logger.level = :trace
logger.trace "This is a trace message"
logger.info "This is an info message"
logger.warn "This is a warning message"
```

The output is as follows:
```bash
==> trace.log <==
2013-08-02 14:15:56.733532 T [35669:70176909690580] MyClass -- This is a trace message
2013-08-02 14:15:56.734273 I [35669:70176909690580] MyClass -- This is an info message
2013-08-02 14:15:56.735273 W [35669:70176909690580] MyClass -- This is a warning message

==> warnings.log <==
2013-08-02 14:15:56.735273 W [35669:70176909690580] MyClass -- This is a warning message
```

### Custom Formatters

The formatting for each appender can be replaced with custom code. To replace the
existing formatter supply a block of code when creating the appender.

Example: Formatter that just returns the Log Struct

```ruby
require 'semantic_logger'

SemanticLogger.default_level = :trace

SemanticLogger.add_appender(STDOUT) do |log|
 # This formatter just returns the log struct as a string
  log.inspect
end

logger = SemanticLogger['Hello']
logger.info "Hello World"
```
Output:

    #<struct SemanticLogger::Base::Log level=:info, thread_name=70167090649820, name="Hello", message="Hello World", payload=nil, time=2012-10-24 10:09:33 -0400, duration=nil, tags=nil, level_index=2>


Example: Replace the default log file formatter

```ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace

SemanticLogger.add_appender('development.log') do |log|
  tags = log.tags.collect { |tag| "[#{tag}]" }.join(" ") + " " if log.tags && (log.tags.size > 0)

  message = log.message.to_s
  message << " -- " << log.payload.inspect if log.payload
  message << " -- " << "#{log.exception.class}: #{log.exception.message}\n#{(log.exception.backtrace || []).join("\n")}" if log.exception

  duration_str = log.duration ? "(#{'%.1f' % log.duration}ms) " : ''

  "#{SemanticLogger::Appender::Base.formatted_time(log.time)} #{log.level.to_s[0..0].upcase} [#{$$}:#{log.thread_name}] #{tags}#{duration_str}#{log.name} -- #{message}"
end
```

Example: Replace the default MongoDB formatter

```ruby
# Log to MongoDB and supply a custom document formatter
mongodb_appender = SemanticLogger::Appender::MongoDB.new(
  :db              => Cache::Work.db,
  :collection_size => 25.gigabytes
) do |log|
    # Return a document (Hash) of the data to be saved to MongoDB
    document = {
      :time        => log.time,
      :host_name   => SemanticLogger::Appender::MongoDB.host_name,
      :pid         => $PID,
      :thread_name => log.thread_name,
      :name        => log.name,
      :level       => log.level,
      :level_index => log.level_index,
    }
    document[:application] = 'MyApplication'
    document[:message]     = SemanticLogger::Appender::MongoDB.strip_colorizing(log.message) if log.message
    document[:duration]    = log.duration if log.duration
    document[:tags]        = log.tags if log.tags && (log.tags.size > 0)
    document[:payload]     = log.payload if log.payload
    document[:exception]   = {
      :name        => log.exception.class.name,
      :message     => log.exception.message,
      :stack_trace => log.exception.backtrace
    } if log.exception
    document
end
SemanticLogger.add_appender(mongodb_appender)
```

## Performance

The traditional logging implementations write their log information to file in the
same thread of execution as the program itself. This means that for every log entry
the program has to wait for the data to be written.

With Semantic Logger it uses a dedicated thread for logging so that writing to
the log file or other appenders does not hold up program execution.

Also, since the logging is in this separate thread there is no impact to program
execution if we decided to add another appender.
For example, log to both a file and a MongoDB collection.

## Log Rotation

Since the log file is not re-opened with every call, when the log file needs
to be rotated, use a copy-truncate operation over deleting the file.

## Why Semantic logging?

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
logback, logging, log4r, central_logger, whoops

## Architecture & Performance

In order to ensure that logging does not hinder the performance of the application
all log entries are written to thread-safe Queue. A separate thread is responsible
for writing the log entries to each of the appenders.

In this way formatting and disk or network write delays will not affect the
performance of the application. Also adding more than one appender does not affect
the runtime performance of the application.

The logging thread is automatically started on initialization. When the program
terminates it will call flush on each of the appenders.

Calling SemanticLogger::Logger#flush will wait until all outstanding log messages
have been written and flushed to their respective appenders before returning.

## Write your own Appender

To write your own appender it should meet the following requirements:

* Inherit from SemanticLogger::Base
* In the initializer connect to the resource being logged to
* Implement #log(log) which needs to write to the relevant resource
* Implement #flush if the resource can be flushed
* Write a test for the new appender

The #log method takes the log struct as a parameter which is described above.

Basic outline for an Appender:

```ruby
require 'semantic_logger'

class SimpleAppender < SemanticLogger::Appender::Base
  def initialize(level=nil, &block)
    # Set the log level and formatter if supplied
    super(level, &block)
  end

  # Display the log struct and the text formatted output
  def log(log)
    # Only log if the supplied level matches or exceeds the level for this appender
    return unless level_index <= (log.level_index || 0)

    # Display the raw log structure
    p log

    # Display the formatted output
    puts formatter.call(log)
  end

  # Optional
  def flush
    puts "Flush :)"
  end
end
```

Sample program calling the above appender:
```ruby
SemanticLogger.default_level = :trace
# Log to file dev.log
SemanticLogger.add_appender('dev.log')
# Also log the above sample appender
SemanticLogger.add_appender(SimpleAppender.new)

logger = SemanticLogger['Hello']
logger.info "Hello World"
```

Look at the [existing appenders](https://github.com/reidmorrison/semantic_logger/tree/master/lib/semantic_logger/appender) for good examples

To have your appender included in the standard list of appenders, submit it along
with complete working tests.
See the [MongoDB Appender Test](https://github.com/reidmorrison/semantic_logger/blob/master/test/appender_mongodb_test.rb) for an example.

## Dependencies

See [.travis.yml](https://github.com/reidmorrison/semantic_logger/.travis.yml) for the list of tested Ruby platforms

The following gems are only required when their corresponding appenders are being used,
and are therefore not automatically included by this gem:
- MongoDB Appender: mongo 1.9.2 or above
- Syslog Appender: syslog_protocol 0.9.2 or above
- Syslog Appender to a remote syslogng server over TCP or UDP: resilient_socket 0.5.0 or above

## Install

    gem install semantic_logger

## Upgrade Notes:

As of SemanticLogger V2.0 the Rails logging is no longer automatically replaced
when including SemanticLogger. Include the [rails_semantic_logger](http://github.com/reidmorrison/rails_semantic_logger)
gem to replace the Rails default logger with SemanticLogger

Meta
----

* Code: `git clone git://github.com/reidmorrison/semantic_logger.git`
* Home: <https://github.com/reidmorrison/semantic_logger>
* Bugs: <http://github.com/reidmorrison/semantic_logger/issues>
* Gems: <http://rubygems.org/gems/semantic_logger>

This project uses [Semantic Versioning](http://semver.org/).

Author
-------

Reid Morrison :: reidmo@gmail.com :: @reidmorrison

Contributors
------------

Marc Bellingrath :: marrrc.b@gmail.com

License
-------

Copyright 2012, 2013, 2014 Reid Morrison

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
