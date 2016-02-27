---
layout: default
---

## Filtering

Filtering is useful to reduce log output for excessive log messages. It is can
be used for example where a Library is logging messages and we do not want to modify
that library.

Additionally a filter can be used to filter out or in specific log messages to certain
appenders. For example, only log messages from specific classes or with specific content
to a specific appender.

### Appender specific log filtering

Filters can be supplied to most appenders on the initializer, or can be setup
by using the accessors. A filter is either a regular expression matching what
messages to include, or is a Proc (Block of code) that returns `true` to allow the
message to be logged, or `false` indicating the message should not be logged.

When using a Proc, it is passed the entire `Log Struct`.
For the format of the `Log Struct`, see [Log Struct](log_struct.html)

Example. Using a regular expression filter, log everything to one file,
log _only_ messages from a particular class to the second file:

~~~ruby
require 'semantic_logger'

# Log everything to development.log
SemanticLogger.add_appender(file_name: 'development.log')

# Log everything except any messages from 'MyClass' to summary.log
appender = SemanticLogger.add_appender(
  file_name: 'my_class.log',
  # Filter out log entries where the class name is 'MyClass'
  filter:    /MyClass/
)

logger1 = SemanticLogger['MyClass']
logger1.info "This will _only_ be logged to 'my_class.log'"

logger2 = SemanticLogger['OtherClass']
logger2.info "This will be logged to development.log and 'my_class.log'"
~~~

Example2. Using a Proc filter, log everything to one file, log everything except
messages from a particular class to the second file:

~~~ruby
require 'semantic_logger'

# Log everything to development.log
SemanticLogger.add_appender(file_name: 'development.log')

# Log all messages from 'MyClass' to summary.log
appender = SemanticLogger.add_appender(
  file_name: 'my_class.log',
  # Filter out log entries where the class name is _not_ 'MyClass'
  filter:    -> log { log.name != 'MyClass' }
)

logger1 = SemanticLogger['MyClass']
logger1.info "This will _not_ be logged to summary.log"

logger2 = SemanticLogger['OtherClass']
logger2.info "This will be logged to summary.log"
~~~

### Logger specific filtering

Filtering can be applied at the logger level, allowing the filtering to only apply
to users of that specific logger instance. This is useful to reduce logging from
a library when it allows its logger to be replaced.

For example, filter out all the `*** Checking` log messages from Resque:

~~~ruby
logger = SemanticLogger[Resque]
# Filter out all messages containing the text beginning with '*** Checking'
logger.filter = Proc.new {|log| log.message !~ /\A\*\*\* Checking/ }

# Give Resque its own logger with the custom filter qpplied to reduce it's verbosity
# when logging to all registered appenders
Resque.logger = logger
~~~

### [Next: Customize ==>](customize.html)
