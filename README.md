semantic_logger
===============

Improved logging for Ruby

* http://github.com/ClarityServices/semantic_logger

### Overview

Semantic Logger takes logging in Ruby to a new level by adding several new
capabilities to the commonly used Logging API:

Dynamic

* Increase the log level at runtime for just one class
* For example enable debug level logging for a single class (logging instance)
  while the program is running to get more detailed logging in production for just that class

Tagged Logging

* Supply custom data to be added to every log entry within a block of code,
  including libraries and existing Gems

High Performance

* Logging is performed in a separate thread so as not to impact performance of
  running code

Customizable

* Custom formatting by destination
* Easy to "roll your own" destination (Appender).
  For example to log to Hadoop, Redis, etc..

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

Drop-in Replacement

* Simple drop-in replacement for the Ruby, or the Rails loggers
* Supports current common logging interface
* No changes to existing to code to use new logger ( other than replacing the logger )

Rails 2 & 3 Support

* Just include the semantic_logger gem into Rails and it will immediately
  replace the existing loggers to improve performance and information
  in the log files

Thread Aware

* Includes the process and thread id information in every log entry

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
  For example only write :info and above to MongoDB
  Or have a second log file for :warn and above log entries

Benchmarking

* The performance of any block of code can be measured and logged at the same time
  depending on the active log level

Semantic Capabilities

* With Semantic Logger it is simple to mix-in additional semantic information with
every log entry
* The application or class name is automatically included for every log entry under
  a specific logging instance
* Includes the duration of blocks of code
* any Hash containing context specific information such as user_id or location information

Beyond Tagged Logging

* Supply entire hash of custom data to be added to the payload of every log entry
  within a block of code, including libraries and existing Gems

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

Thread Safe

* Semantic Logger is completely thread safe and all methods can be called
  concurrently from any thread
* Tagged logging keeps any tagging data on a per-thread basis to ensure that
  tags from different threads are not inter-mingled

### Introduction

SemanticLogger is a Logger that supports logging of meta-data, along with text messages
to multiple appenders

An appender is a Logging destination such as a File, MongoDB collection, etc..
Multiple Appenders can be active at the same time. All log entries are written
to each appender.

Machines can understand the logged data without having to use
complex Regular Expressions or other text parsing techniques

SemanticLogger, sits on top of existing logger implementations and can also
be used as a drop in replacement for existing Ruby loggers.
This allows the existing logging to be replaced immediately with the
SemanticLogger Appenders, and over time the calls can be replaced with ones
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
Rails.logger.info("Queried table",
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

Since SemanticLogger can call existing Loggers, it does not force end-users
to have to adopt a Semantic aware adapter. Although, such adapters create
tremendous value in the problem monitoring and determination processes.

### Logging API

#### Standard Logging methods

The Semantic Logger logging API supports the existing logging interface for
the Rails and Ruby Loggers. For example:

```ruby
logger.info("Hello World")
```

Or to query whether a specific log level is set

```ruby
logger.info?
```

The following logging methods are available

```ruby
trace(message, payload=nil, &block)
debug(message, payload=nil, &block)
info(message, payload=nil, &block)
warn(message, payload=nil, &block)
error(message, payload=nil, &block)
fatal(message, payload=nil, &block)
```

Parameters

- message: The text message to log.
  Mandatory only if no block is supplied
- payload: Optional, either a Ruby Exception object or a Hash
- block:   The optional block is executed only if the corresponding log level
  is active. Can be used to prevent unnecessary calculations of debug data in
  production.

Examples:

```ruby
logger.debug("Calling Supplier")

logger.debug("Calling Supplier", :request => 'update', :user => 'Jack')

logger.debug { "A total of #{result.inject(0) {|sum, i| i+sum }} were processed" }
```

### Exceptions

The Semantic Logger adds an extra parameter to the existing log methods so that
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

#### Payload

The Semantic Logger adds an extra parameter to the existing log methods so that
additional payload can be logged, such as a Hash or a Ruby Exception object.

```ruby
logger.info("Oops external call failed", :result => :failed, :reason_code => -10)
```

The additional payload is machine readable so that we don't have to write complex
regular expressions so that a program can analyze log output. With the MongoDB
appender the payload is written directly to MongoDB as part of the document and
is therefore fully searchable

#### Benchmarking

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
benchmark_trace(message, params=nil, &block)
benchmark_debug(message, params=nil, &block)
benchmark_info(message, params=nil, &block)
benchmark_warn(message, params=nil, &block)
benchmark_error(message, params=nil, &block)
benchmark_fatal(message, params=nil, &block)
```

Parameters

- message: The mandatory text message to log.
- params:
```
  :log_exception
    Control whether or how an exception thrown in the block is
    reported by SemanticLogger. Values:
    :full
      Log the exception class, message, and backtrace
    :partial
      Log the exception class and messag
      The backtrace will not be logged
    :off
      Any unhandled exception from the block will not be logged

  :min_duration
    Only log if the block takes longer than this duration in ms
    Default: 0.0

  :payload
    Optional, either a Ruby Exception object or a Hash
```

#### Logging levels

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

#### Changing the Class name for Log Entries

When Semantic Logger is included on a Rails project it automatically replaces the
loggers for Rails, ActiveRecord::Base, ActionController::Base, and ActiveResource::Base
with wrappers that set their Class name. For example in semantic_logger/railtie.rb:

```ruby
ActiveRecord::Base.logger = SemanticLogger::Logger.new(ActiveRecord)
```

By replacing their loggers we now get the class name in the text logging output:

    2012-08-30 15:24:13.439 D [47900:main] ActiveRecord --   SQL (12.0ms)  SELECT `schema_migrations`.`version` FROM `schema_migrations`

It is recommended to include a class specific logger for all major classes that will
be logging. For Example:

```ruby
require 'sync_attr'
require 'semantic_logger'

class ExternalSupplier
  # Gem sync_attr is a dependency of semantic_logger so is already installed
  include SyncAttr

  # Lazy initializes the class logger on it's first call in a thread-safe way
  sync_cattr_reader :logger do
    SemanticLogger::Logger.new(self)
  end

  def call(params)
    self.class.logger.benchmark_info "Calling external interface" do
        # Code to call external service ...
    end
  end
end
```

This will result in the log output identifying the log entry as from the ExternalSupplier class

    2012-08-30 15:37:29.474 I [48308:ScriptThreadProcess: script/rails] (5.2ms) ExternalSupplier -- Calling external interface

[SyncAttr](https://github.com/ClarityServices/sync_attr) is a gem that supports
lazy loading and thread-safe initialization of class attributes

Extract from a Rails log file after adding the semantic_logger gem:

```
2012-10-19 12:05:46.736 I [35940:JRubyWorker-10] Rails --

Started GET "/" for 127.0.0.1 at 2012-10-19 12:05:46 +0000
2012-10-19 12:05:47.318 I [35940:JRubyWorker-10] ActionController --   Processing by AdminController#index as HTML
2012-10-19 12:05:47.633 D [35940:JRubyWorker-10] ActiveRecord --   User Load (2.0ms)  SELECT `users`.* FROM `users` WHERE `users`.`id` = 1 LIMIT 1
2012-10-19 12:05:49.833 D [35940:JRubyWorker-10] ActiveRecord --   Role Load (2.0ms)  SELECT `roles`.* FROM `roles`
2012-10-19 12:05:49.868 D [35940:JRubyWorker-10] ActiveRecord --   Role Load (1.0ms)  SELECT * FROM `roles` INNER JOIN `roles_users` ON `roles`.id = `roles_users`.role_id WHERE (`roles_users`.user_id = 1 )
2012-10-19 12:05:49.885 I [35940:JRubyWorker-10] ActionController -- Rendered menus/_control_system.html.erb (98.0ms)
2012-10-19 12:05:51.014 I [35940:JRubyWorker-10] ActionController -- Rendered layouts/_top_bar.html.erb (386.0ms)
2012-10-19 12:05:51.071 D [35940:JRubyWorker-10] ActiveRecord --   Announcement Load (20.0ms)  SELECT `announcements`.* FROM `announcements` WHERE `announcements`.`active` = 1 ORDER BY created_at desc
2012-10-19 12:05:51.072 I [35940:JRubyWorker-10] ActionController -- Rendered layouts/_announcement.html.erb (26.0ms)
2012-10-19 12:05:51.083 I [35940:JRubyWorker-10] ActionController -- Rendered layouts/_flash.html.erb (4.0ms)
2012-10-19 12:05:51.109 I [35940:JRubyWorker-10] ActionController -- Rendered layouts/_footer.html.erb (16.0ms)
2012-10-19 12:05:51.109 I [35940:JRubyWorker-10] ActionController -- Rendered admin/index.html.erb within layouts/base (1329.0ms)
2012-10-19 12:05:51.113 I [35940:JRubyWorker-10] ActionController -- Completed 200 OK in 3795ms (Views: 1349.0ms | ActiveRecord: 88.0ms | Mongo: 0.0ms)
```

#### Tagged Logging

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

#### Beyond Tagged Logging

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

### Configuration

The Semantic Logger follows the principle where multiple appenders can be active
at the same time. This allows one to log to MongoDB and the Rails
ActiveResource::BufferedLogger at the same time.

#### Rails Configuration

Add the following line to Gemfile

```ruby
gem 'semantic_logger'
```

Also add the following line to Gemfile if you want to log to MongoDB

```ruby
gem 'mongo'
```

Install required gems with bundler

    bundle install

This will automatically replace the standard Rails logger with Semantic Logger
which will write all log data to the configured Rails logger.

By default Semantic Logger will detect the log level from Rails. To set the
log level explicitly, add the following line to
config/environments/production.rb inside the Application.configure block

```ruby
config.log_level = :trace
```

To log to both the Rails logger and MongoDB add the following lines to
config/environments/production.rb inside the Application.configure block

```ruby
config.after_initialize do
  # Re-use the existing MongoDB connection, or create a new one here
  db = Mongo::Connection.new['production_logging']

  # Besides logging to the standard Rails logger, also log to MongoDB
  config.semantic_logger.appenders << SemanticLogger::Appender::MongoDB.new(
    :db              => db,
    :collection_size => 25.gigabytes
  )
end
```

#### Custom Formatters

The formatting for each appender can be replaced with custom code. To replace the
existing formatter supply a block of code when creating the appender.

For example to replace the Rails or Ruby text log formatter, in the environment configuration file:

```ruby
    config.after_initialize do
      # Since the Rails logger is already initialized, replace its default formatter
      config.semantic_logger.appenders.first.formatter = Proc.new do |log|
          # log is a struct with the following fields:
          #
          # level
          #   Log level of the supplied log call
          #   :trace, :debug, :info, :warn, :error, :fatal
          #
          # thread_name
          #   Name of the thread in which the logging call was called
          #
          # name
          #   Class name supplied to the logging instance
          #
          # message
          #   Text message to be logged
          #
          # payload
          #   Optional Hash or Ruby Exception object to be logged
          #
          # time
          #   The time at which the log entry was created
          #
          # duration
          #   The time taken to complete a benchmark call
          #
          # tags
          #   Any tags active on the thread when the log call was made
          #

          message = log.message.to_s
          tags = log.tags.collect { |tag| "[#{tag}]" }.join(" ") + " " if log.tags && (log.tags.size > 0)

          if log.payload
            if log.payload.is_a?(Exception)
              exception = log.payload
              message << " -- " << "#{exception.class}: #{exception.message}\n#{(exception.backtrace || []).join("\n")}"
            else
              message << " -- " << log.payload.inspect
            end
          end

          str = "#{log.time.strftime("%Y-%m-%d %H:%M:%S")}.#{"%06d" % log.time.usec} #{"%-05s" % log.level.to_s.upcase} [#{$$}:#{log.thread_name}] #{tags}#{log.name} -- #{message}"
          str << " (#{'%.1f' % log.duration}ms)" if log.duration
          str
      end
    end
```

For example to replace the MongoDB formatter, in the environment configuration file:

```ruby
    config.after_initialize do
      # Log to MongoDB and supply a custom document formatter
      mongodb_appender = SemanticLogger::Appender::MongoDB.new(
        :db              => Cache::Work.db,
        :collection_size => 25.gigabytes
      ) do |log|
          # log is a struct with the following fields:
          # level
          #   Log level of the supplied log call
          #   :trace, :debug, :info, :warn, :error, :fatal
          #
          # thread_name
          #   Name of the thread in which the logging call was called
          #
          # name
          #   Class name supplied to the logging instance
          #
          # message
          #   Text message to be logged
          #
          # payload
          #   Optional Hash or Ruby Exception object to be logged
          #
          # time
          #   The time at which the log entry was created
          #
          # duration
          #   The time taken to complete a benchmark call
          #
          # tags
          #   Any tags active on the thread when the log call was made
          #

          # Return a document (Hash) of the data to be saved to MongoDB
          document = {
            :time        => log.time,
            :host_name   => SemanticLogger::Appender::MongoDB.host_name,
            :pid         => $PID,
            :thread_name => log.thread_name,
            :name        => log.name,
            :level       => log.level,
          }
          document[:application] = 'MyApplication'
          document[:message]     = SemanticLogger::Appender::MongoDB.strip_colorizing(log.message) if log.message
          document[:duration]    = log.duration if log.duration
          document[:tags]        = log.tags if log.tags && (log.tags.size > 0)

          if log.payload
            if log.payload.is_a?(Exception)
              exception = log.payload
              document[:payload] = {
                :exception => exception.class.name,
                :message   => exception.message,
                :backtrace => exception.backtrace
              }
            else
              document[:payload] = log.payload
            end
          end
          document
      end
      config.semantic_logger.appenders << mongodb_appender
    end
```

### SysLog and other standard loggers

To write log entries to a Syslog logger or any other logger of your choice,
that conforms the standard Ruby Logger API, Semantic Logger has an Appender to
use that logger.

For example to configure rails to also log to the Syslogger gem:
```ruby
config.after_initialize do
  # Besides logging to the local file also log to Syslogger
  config.semantic_logger.appenders << SemanticLogger::Appender::Wrapper.new(Syslogger.new("yourappname"))
end
```

### Performance

The traditional logging implementations write their log information to file in the
same thread of execution as the program itself. This means that for every log entry
the program has to wait for the data to be written.

With Semantic Logger it uses a dedicated thread for logging so that writing to
the log file or other appenders does not hold up program execution.

Also, since the logging is in this separate thread there is no impact to program
execution if we decided to add another appender.
For example, log to both a file and a MongoDB collection.

### Log Rotation

Since the log file is not re-opened with every call, when the log file needs
to be rotated, use a copy-truncate operation over deleting the file.

### Why Semantic logging?

Just as there is the initiative to add Semantic information to data on the web
so that computers can directly understand the content without having to resort
to complex regular expressions or machine learning techniques, it is important
to be able to do the same with log files or data.

Semantic Logger allows every log entry to have not only a message, but a payload
that can be written to a file or a NOSQL destination.

Once the logging data is in the NOSQL data store it can be queried quickly and
efficiently. Some SQL data stores also allow complex data types that could be used
for storing and querying the logging data

### Architecture & Performance

In order to ensure that logging does not hinder the performance of the application
all log entries are written to thread-safe Queue. A separate thread is responsible
for writing the log entries to each of the appenders.

In this way formatting and disk or network write delays will not affect the
performance of the application. Also adding more than one appender does not affect
the runtime performance of the application.

The additional thread is automatically started on initialization. When the program
terminates it will complete writing out all log data and flush the appenders before
the program exits.

Calling SemanticLogger::Logger#flush will wait until all outstanding log messages
have been written and flushed to their respective appenders before returning.
Since all logging is now from this thread calling flush is no longer thread
specific.

### Write your own Appender

To write your own appender it should meet the following requirements:

* Inherit from SemanticLogger::Base
* In the initializer connect to the resource being logged to
* Implement #log(log) which needs to write to the relevant resource
* Implement #flush if the resource can be flushed
* Write a test for the new appender

The #log method takes the log struct as a parameter which is defined as follows:
```ruby
Log = Struct.new(:level, :thread_name, :name, :message, :payload, :time, :duration, :tags, :level_index)
```
level

* Log level of the supplied log call
* :trace, :debug, :info, :warn, :error, :fatal

thread_name

* Name or id of the thread in which the logging call was called

name

* Class name supplied to the logging instance

message

* Text message to be logged

payload [Hash|Exception]

* Optional Hash or Ruby Exception object to be logged

time [Time]

* The time at which the log entry was created

duration [Float]

* The time taken in milli-seconds to complete a benchmark call

tags [Array<String>]

* Any tags active on the thread when the log call was made

level_index

* Internal use only. Index of the log level

Basic outline for an Appender:

```ruby
require 'semantic_logger'

class SimpleAppender < SemanticLogger::Base
  def initialize(level=nil, &block)
    # Set the log level and formatter if supplied
    super(level, &block)
  end

  # Just display the log struct
  def log(log)
    p log
  end

  # Optional
  def flush
    puts "Flush :)"
  end
end
```

Sample program calling the above appender:
```ruby
SemanticLogger::Logger.default_level = :trace
# Log to file dev.log
SemanticLogger::Logger.appenders << SemanticLogger::Appender::File.new('dev.log')
# Also log the above sample appender
SemanticLogger::Logger.appenders << SimpleAppender.new

logger = SemanticLogger::Logger.new('Hello')
logger.info "Hello World"
```

Look at the [existing appenders](https://github.com/ClarityServices/semantic_logger/tree/master/lib/semantic_logger/appender) for good examples

To have your appender included in the standard list of appenders follow the fork
instructions below.
Very Important: New appenders will not be accepted without complete working tests.
See the [MongoDB Appender Test](https://github.com/ClarityServices/semantic_logger/blob/master/test/appender_mongodb_test.rb) for an example.

### Dependencies

- Ruby MRI 1.8.7, 1.9.3 (or above) Or, JRuby 1.6.3 (or above)
- Optional: Rails 3.0.10 (or above)
- Optional: To log to MongoDB, Mongo Ruby Driver 1.5.2 or above

### Install

    gem install semantic_logger

To log to MongoDB

    gem install mongo

### Future

- Configuration file to support setting the log level for a specific class
- Configuration file to support adding appenders
- Based on demand add direct appenders for: Syslog, hadoop, redis

Development
-----------

Want to contribute to Semantic Logger?

First clone the repo and run the tests:

    git clone git://github.com/ClarityServices/semantic_logger.git
    cd semantic_logger
    rake test

Feel free to ping the mailing list with any issues and we'll try to resolve it.

Contributing
------------

Once you've made your great commits:

1. [Fork](http://help.github.com/forking/) semantic_logger
2. Create a topic branch - `git checkout -b my_branch`
3. Push to your branch - `git push origin my_branch`
4. Create an [Issue](http://github.com/ClarityServices/semantic_logger/issues) with a link to your branch
5. That's it!

Meta
----

* Code: `git clone git://github.com/ClarityServices/semantic_logger.git`
* Home: <https://github.com/ClarityServices/semantic_logger>
* Bugs: <http://github.com/reidmorrison/semantic_logger/issues>
* Gems: <http://rubygems.org/gems/semantic_logger>

This project uses [Semantic Versioning](http://semver.org/).

Authors
-------

Reid Morrison :: reidmo@gmail.com :: @reidmorrison

License
-------

Copyright 2012 Clarity Services, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
