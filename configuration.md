---
layout: default
---

## Configuration

In a stand-alone or non-rails environment we can easily log to a file called
'development.log' as follows:

```ruby
require 'semantic_logger'
SemanticLogger.add_appender('development.log')

logger = SemanticLogger['Example']
logger.info "Hello World"
```

By default it will only log `:info` and above, to log everything to the log file:

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

To log `:debug` and above to a log file, `:error` and above to `$stderr`, and `:info`
and above to MongoDB:

```ruby
require 'semantic_logger'
require 'mongo'

SemanticLogger.default_level = :debug
SemanticLogger.add_appender('development.log')
SemanticLogger.add_appender($stderr, :error)

mongo_appender = SemanticLogger::Appender::MongoDB.new(
  db:              Mongo::MongoClient.new['production_logging'],
  collection_size: 25*1024**3, # 25.gigabytes
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
This can be achieved by including `SemanticLogger::Loggable`:

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
