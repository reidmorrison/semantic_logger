semantic_logger
===============

Ruby and Rails Logger enhanced with semantic capabilities, high performance, standardized
logging with multiple appenders

* http://github.com/ClarityServices/semantic_logger

### Introduction

SemanticLogger is a Logger that supports logging of meta-data, along with text messages

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
with wrappers that set their Class name. For example in railtie.rb:

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

#### Tagged Logging

```ruby
logger.tagged(tracking_number) do
  logger.debug("Hello World")
  # ...
end
```

#### Payload injected logging

```ruby
logger.with_payload(:user => 'Jack') do
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

### Architecture & Performance

In order to ensure that logging does not hinder the performance of the application
all log entries are written to thread-safe Queue. A separate thread is responsible
for writing the log entries to each of the appenders.

In this way formatting and disk or network write delays will not affect the
performance of the application. Also adding more than one appender does not affect
the runtime performance of the application

The additional thread is automatically started on initialization. When the program
terminates it will complete writing out all log data and flush the appenders before
the program exits.

Calling SemanticLogger::Logger#flush will wait until all outstanding log messages
have been written and flushed to their respective appenders before returning.
Since all logging is now from this thread calling flush is no longer thread
specific.

### Dependencies

- Ruby MRI 1.8.7 (or above) Or, JRuby 1.6.3 (or above)
- Optional: Rails 3.0.10 (or above)
- Optional: To log to MongoDB, Mongo Ruby Driver 1.5.2 or above

### Install

    gem install semantic_logger

To log to MongoDB

    gem install mongo

### Future

- Web Interface to view and search log information stored in MongoDB

Development
-----------

Want to contribute to Semantic Logger?

First clone the repo and run the tests:

    git clone git://github.com/ClarityServices/semantic_logger.git
    cd semantic_logger
    ruby -S rake test

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
