---
layout: default
---

## Filtering

A filter controls which log entries are written, selecting them by class name or by any property
of the entry. It is useful to quiet a noisy library without modifying it, or to send only certain
messages to a particular appender.

A filter is one of:

* A **regular expression**, matched against the class name of the logger. Only entries whose class
  name matches are logged.
* A **Proc**, which receives the entire log event and returns `true` to keep the entry, or `false`
  to drop it. For the structure of the log event, see [Log Event](log_struct.html).

Filters can be applied at two levels:

* **Per appender**, where the filter affects only what that one destination writes.
* **Per logger**, where the filter affects every appender, but only for that one logger instance.

### Appender specific log filtering

Supply a `filter:` when adding an appender, or set it afterwards with the `filter=` accessor.

Example. Using a regular expression filter, log everything to one file,
log _only_ messages from a particular class to the second file:

~~~ruby
require "semantic_logger"

# Log everything to development.log
SemanticLogger.add_appender(file_name: "development.log")

# Log _only_ messages from "MyClass" to my_class.log
appender = SemanticLogger.add_appender(
  file_name: "my_class.log",
  # Only include log entries where the class name matches "MyClass"
  filter:    /MyClass/
)

logger1 = SemanticLogger["MyClass"]
logger1.info "This will be logged to development.log and my_class.log"

logger2 = SemanticLogger["OtherClass"]
logger2.info "This will _only_ be logged to development.log"
~~~

Example Using a Proc filter, log everything to one file, log everything except
messages from a particular class to the second file:

~~~ruby
require "semantic_logger"

# Log everything to development.log
SemanticLogger.add_appender(file_name: "development.log")

# Log all messages from "MyClass" to summary.log
appender = SemanticLogger.add_appender(
  file_name: "my_class.log",
  # Filter out log entries where the class name is _not_ "MyClass"
  filter:    -> log { log.name != "MyClass" }
)

logger1 = SemanticLogger["MyClass"]
logger1.info "This will _not_ be logged to summary.log"

logger2 = SemanticLogger["OtherClass"]
logger2.info "This will be logged to summary.log"
~~~

Example using filter to change log messages.

Resque logs the entire job payload which may contain private information.
Strip out the job data since from the following log messages:
* log "got: #{job.inspect}"
* log "done: #{job.inspect}"

~~~ruby
Resque.logger.filter = -> log do
  if (log.name == "Resque") && (match = log.message.to_s.match(/\A(got|done): /))
    log.message = match[1]
  end
  # After the message has been modified, make sure it is logged:
  true
end
~~~


### Logger specific filtering

Filtering can be applied at the logger level, allowing the filtering to only apply
to users of that specific logger instance. This is useful to reduce logging from
a library when it allows its logger to be replaced.

For example, filter out all the `*** Checking` log messages from Resque:

~~~ruby
logger = SemanticLogger[Resque]
# Filter out all messages containing the text beginning with "*** Checking"
logger.filter = Proc.new {|log| log.message !~ /\A\*\*\* Checking/ }

# Give Resque its own logger with the custom filter applied to reduce its verbosity
# when logging to all registered appenders
Resque.logger = logger
~~~

### [Next: Customize ==>](customize.html)
