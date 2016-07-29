---
layout: default
---

## Programming Guide

### Logging levels

The following logging levels are available through Semantic Logger

    :trace, :debug, :info, :warn, :error, :fatal

The log levels are listed above in the order of precedence with the most detail to the least.
For example `:debug` would include `:info`, `:warn`, `:error`, `:fatal` levels but not `:trace`
And `:fatal` would only log `:fatal` error messages and nothing else

`:trace` is a new level that is often used for tracing low level calls such
as the data sent or received to external web services. It is also commonly used
in the development environment for low level trace logging of methods calls etc.

### Changing the global default log level

By default Semantic Logger will only log `:info` and above, to log everything to
the log file set the global default log level to `:trace`:

~~~ruby
require 'semantic_logger'

# Override the default log level of :info so that :debug and :trace are also logged
SemanticLogger.default_level = :trace

SemanticLogger.add_appender(file_name: 'development.log', formatter: :color)

logger = SemanticLogger['MyClass']
logger.info "Hello World"
logger.trace "Low level trace information"
~~~

All loggers and appenders will by default use the global `SemanticLogger.default_level`
unless they have been explicity set to another level. In which case changing
`SemanticLogger.default_level` will not affect that particular logger or appender.

### Creating an instance of a logger

To create a stand-alone logger instance by supplying the name of the class/application:

~~~ruby
logger = SemanticLogger['MyClass']
~~~

Or, even better, pass the actual class itself:

~~~ruby
logger = SemanticLogger[MyClass]
~~~

A logger instance should be created for every class so that it's log entries
can be uniquely identified from logging entries from other classes.

All logger instances forward their log messages to the global Appender Thread that
does the actual logging to each appender, see [Appenders](appenders.html) for a list of available
Appenders.

#### Using the SemanticLogger::Loggable Mixin

Rather than creating logger instances above inside classes it is recommended to
use the SemanticLogger::Loggable Mixin by adding the following include:

~~~ruby
  include SemanticLogger::Loggable
~~~

For Example:

~~~ruby
class Supplier
  # Include class and instance logger variables
  include SemanticLogger::Loggable

  def self.some_class_method
    logger.debug 'logger is accessible from class methods'
  end

  def call_supplier
    logger.debug "logger is accessible from instance methods"
  end
end
~~~

This will result in the log output identifying the log entry as from the `Supplier` class

    2012-08-30 15:37:29.474 I [48308:main] Supplier -- logger is accessible from instance methods

### Standard Logging methods

The Semantic Logger logging API supports the existing logging interface for
the Rails and Ruby Loggers. For example:

~~~ruby
logger.info("Hello World")
~~~

Or to query whether a specific log level is set

~~~ruby
logger.info?
~~~

The following traditional logging methods are available

~~~ruby
logger.trace("Low level trace information such as data sent over a socket")
logger.debug("Debugging information to aid with problem determination")
logger.info("Informational message such as request received")
logger.warn("Warn about something in the system")
logger.error("An error occurred during processing")
logger.fatal("Oh no something really bad happened")
~~~

Each of the above calls can take additional parameters, for example:

~~~ruby
log.info(message, payload_or_exception=nil, exception=nil, &block)
~~~

Parameters

- `message`:   The text message to log.
  Mandatory only if no block is supplied
- `payload_or_exception`:   Optional, either a Ruby Exception object or a Hash
- `exception`: Optional, Ruby Exception object. Allows both an exception and a payload to be logged
- `block`:     The optional block is executed only if the corresponding log level is active.
By supplying a block, it is only evaluated when the log level meets or exceeds the supplied log level.
This can be used to prevent the block from being evaluated in production environments.

Examples:

~~~ruby
logger.debug("Calling Supplier")

logger.debug("Calling Supplier", :request => 'update', :user => 'Jack')

logger.trace { "A total of #{result.inject(0) {|sum, i| i+sum }} were processed" }
~~~

### Exceptions

The Semantic Logger adds an optional parameter to the existing log methods so that
a corresponding Exception can be logged in a standard way

~~~ruby
begin
  # ... Code that can raise an exception
rescue Exception => exception

  # Log the exception as an error
  logger.error("Oops external call failed", exception)

  # Re-raise or handle the exception
  raise exception
end
~~~

### Payload

The Semantic Logger adds an extra parameter to the existing log methods so that
additional payload can be logged, such as a Hash or a Ruby Exception object.

~~~ruby
logger.info("Oops external call failed", result: :failed, reason_code: -10)
~~~

The additional payload is machine readable so that we don't have to write complex
regular expressions so that a program can analyze log output. With the MongoDB
appender the payload is written directly to MongoDB as part of the document and
is therefore fully searchable

### Benchmarking

Another common logging requirement is to measure the time it takes to execute a block
of code based on the log level. For example:

~~~ruby
logger.measure_info "Called external interface" do
  # Code to call external service ...
end
~~~

The following output will be written to file:

    2012-08-30 15:37:29.474 I [48308:ScriptThreadProcess: script/rails] (5.2ms) Rails -- Called external interface

The log message is only written once the block completes and includes how long it
took to complete.

If an exception is raised during the block, the exception message will be logged
at the same log level as the measure along with the duration and message.
After logging the exception is re-raised unchanged.

The following measureing methods are available:

~~~ruby
logger.measure_trace("Low level trace information such as data sent over a socket")
logger.measure_debug("Debugging information to aid with problem determination")
logger.measure_info("Informational message such as request received")
logger.measure_warn("Warn about something in the system")
logger.measure_error("An error occurred during processing")
logger.measure_fatal("Oh no something really bad happened")
~~~

The log level can be supplied dynamically as the first parameter to:

~~~ruby
logger.measure(:info, "Informational message such as request received")
~~~

Each of the above calls take additional optional parameters:

~~~ruby
log.measure_info(message, params=nil) do
  # Measure how long it takes to run this block of code
end
~~~

Benchmark calls take two parameters, the first is a mandatory text message, the
second is a Hash of settings:

#### `:log_exception` [Symbol]

Control whether or how an exception thrown in the block is
reported by Semantic Logger. Values:

- `:full`
     Log the exception class, message, and backtrace
- `:partial`
     Log the exception class and message. The backtrace will not be logged
- `:off`
     Any unhandled exception raised in the block will not be logged
- Default: :partial

#### `:min_duration` [Float]

Only log if the block takes longer than this duration in `ms`

Very useful to make a log entry only appear when the specified minimum duration
has been exceeded, which is ideal for isolating the cause of application slow-downs.

Default: 0.0 ( Always log )

#### `:payload` [Hash]

Optional, Hash payload

#### `:exception` [Exception]

Optional, Ruby Exception object to log along with the duration of the supplied block

#### `:duration` [Float]

- Optional, supply the duration in ms that is logged when a block is not supplied
- If a block is not supplied then :duration is mandatory
- If a block is supplied :duration is ignored

#### `:metric` [Object]

Optional, when this parameter is supplied all subscribers will be notified of this
metric, along with the Log Struct described below

#### `:silence` [Symbol]

Optional, the log level to silence all log messages to within the block.
`silence` is thread-safe and only affects messages logged on the current thread.

#### `:on_exception_level` [Symbol]

Optional, If an exception is raised, increase the log level to this level

Example

~~~ruby
logger.measure_info "Called external interface",
    log_exception: :full,
    min_duration:  100,
    metric:        'Custom/Supplier/process' do
  # Code to call external service ...
end
~~~

If the duration is already available, it is possible to use the same measure logging
and manually supply the duration without a block. This ensures that the duration is
logged in a semantic way rather than inserting the duration into the text message itself.

~~~ruby
duration = Time.now - start_time
logger.measure_info "Called external interface", duration: duration
~~~

Note: Either a code block or `:duration` must be supplied on all measure calls

### Tagged Logging

Tagged logging adds the specified tags to every log message within the supplied block.
If a new thread is created within the block the logging tags are not automatically
copied to that thread. Look into [Parallel Minion](https://github.com/reidmorrison/parallel_minion)
for a library that creates threads and automatically copies across any logging tags to the
new thread.


Using Tagged logging is critical in any highly concurrent environment so that
one can quickly find all related log entries across all levels of code, and threads.

~~~ruby
tracking_number = '15354128'

logger.tagged(tracking_number) do
  # All log entries in this block will include the 'tracking_number' logging tag
  logger.debug("Hello World")
end
~~~

### Beyond Tagged Logging

Blocks of code can be tagged with not only values, but can be tagged with
entire hashes of data. The additional hash of data will be merged into
the payload of every log entry

~~~ruby
logger.with_payload(:user => 'Jack', :zip_code => 12345) do
  # All log entries in this block will include the above payload hash
  logger.debug("Hello World")
end
~~~

### Named threads

Semantic Logger logs the name or id of the thread in every log message.

On Ruby MRI the thread name is by default the thread's object_id, For example: 70184354571980

~~~
2013-11-07 16:25:14.279627 I [35841:70184354571980] (0.0ms) ExternalSupplier -- Calling external interface
~~~

To set a custom name for any thread so that it shows up in the logger:

~~~ruby
Thread.current.name = "User calculation thread 32"
~~~

Sample output:

~~~
2013-11-07 16:26:02.744139 I [35841:User calculation thread 32] (0.0ms) ExternalSupplier -- Calling external interface
~~~

When running JRuby, `Thread.current.name` will also set the underlying thread name in the JVM
which is very useful when monitoring the JVM via JMX using tools such as jconsole.

#### NOTE:

Make sure that the assigned thread name is unique otherwise it will be difficult
to distinguish between concurrently running threads if they have the same name.

For example, use the current thread object_id to ensure uniqueness:

~~~ruby
Thread.current.name = "Worker Thread:#{Thread.current.object_id}"
~~~

### Silencing noisy logs

Silence noisy log levels by changing the default_level within the block

This setting is thread-safe and only applies to the current thread

Any threads spawned from within the block will not be affected by `silence`

~~~ruby
# Silence all logging below :error level
logger.silence do
 logger.info "this will _not_ be logged"
 logger.warn "this neither"
 logger.error "but errors will be logged"
end
~~~

`silence` can also lower the log level within the supplied block. For example
to increase log information in diagnosing a specific issue.

~~~ruby
# Perform trace level logging within the block, even when the default is higher
SemanticLogger.default_level = :info

logger.debug 'this will _not_ be logged'

logger.silence(:trace) do
 logger.debug "this will be logged"
end
~~~

#### Note

`silence` does not affect any loggers which have had their log level set
explicitly. I.e. That do not rely on the global default level

### Debug logging as Trace

Some third party gems log a large amount of information at debug since they
do not use Semantic Logger and do not have access to the `:trace` level for
logging.

To map the `:debug` logging calls for these existing libraries to `:trace`, replace
its logger with an instance of `DebugAsTraceLogger::SemanticLogger`

~~~ruby
# Example, log debug level messages as trace:
logger = SemanticLogger::DebugAsTraceLogger.new('NoisyLibrary')

# This will be logged as :trace
logger.debug 'Some very low level noisy message'
~~~

### Changing the log level for a single class at runtime

Since the logger is class specific, its log level can be changed dynamically at runtime.
For example, to temporarily set the log level to `:trace` to diagnose an issue:

~~~ruby
require 'semantic_logger'

SemanticLogger.default_level = :info
SemanticLogger.add_appender(file_name: 'example.log', formatter: :color)

class ExternalSupplier
  # Lazy load logger class variable on first use
  include SemanticLogger::Loggable

  def call_supplier(amount, name)
    logger.trace "Calculating with amount", { :amount => amount, :name => name }

    # Measure and log on completion how long the call took to the external supplier
    logger.measure_info "Calling external interface" do
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

# Change the log level back to the global default level
ExternalSupplier.logger.level = nil
~~~

Below is the output from the above example showing the `:trace` log level message
that was written during the second call to the ExternalSupplier:

~~~
2013-11-07 16:19:26.496 I [35674:main] (0.0ms) ExternalSupplier -- Calling external interface

2013-11-07 16:19:26.683 T [35674:main] ExternalSupplier -- Calculating with amount -- {:amount=>100, :name=>"Jack"}
2013-11-07 16:19:26.683 I [35674:main] (0.0ms) ExternalSupplier -- Calling external interface
~~~

#### Change the log level without using signals

If the application has another means of communicating without needing signals,
the global default log level can be modified using `SemanticLogger.default_level=`

~~~ruby
# Change the global default logging level for active loggers
SemanticLogger.default_level = :debug
~~~

### Flushing the logs

Semantic Logger automatically flushes all appenders ( log files, etc. ) when a process
exits.

The `flush` method is not defined for Semantic Logger instances since there could be
many logging instances, sometimes one per class.

To perform a global flush of all appenders and to wait for any outstanding queued
messages to be written:

~~~ruby
# Flush all appenders and wait for them to complete flushing
SemanticLogger.flush
~~~

### Replacing loggers for other Gems

Rails Semantic Logger already replaces the loggers for the following Gems, but
if Semantic Logger is being used stand-alone, then these need to be called from
within your code as needed:

~~~ruby
# Replace the Resque Logger
Resque.logger = SemanticLogger[Resque] if defined?(Resque) && Resque.respond_to?(:logger)

# Replace the Sidekiq logger
Sidekiq::Logging.logger = SemanticLogger[Sidekiq] if defined?(Sidekiq)

# Replace the Mongoid Logger
Mongoid.logger = SemanticLogger[Mongoid] if defined?(Mongoid)
Moped.logger   = SemanticLogger[Moped] if defined?(Moped)
~~~

### Wrapped Exceptions

Sometimes libraries wrap exceptions such as IOError with their own exceptions so that these exceptions
are easily identified as coming from that library. To do this the library exception should include
an attribute called `cause` in which to hold the original exception, such as an IOError instance.

In the library, include the `cause` attribute to any wrapping exceptions:

~~~ruby
class ALibraryIOException < StandardError
  attr_reader :cause

  def initialize(message, cause)
    @cause = cause
    super(message)
  end
end
~~~

In the library, when an exception is raised, include the causing exception:

~~~ruby
class ALibrary
  def oh_no
    f = File.new('filename', 'w')
    # Will raise: IOError: not opened for reading
    f.read
  rescue IOError => exception
    message = 'Failed to write to file'
    # Pass the causing exception to the wrapping exception 
    raise ALibraryIOException.new(message, exception)
  end
end
~~~

Example Application Code:

~~~ruby
class MyApp
  include SemanticLogger::Loggable

  def perform
    lib = ALibrary.new
    lib.oh_no
  rescue ALibraryIOException => exc
    # Semantic Logger will log both the exception and the causing exception
    logger.error('Failed calling library', exc)
  end
end
~~~

Call the application:

~~~ruby
SemanticLogger.add_appender(io: STDOUT, formatter: :color)
MyApp.new.perform
~~~

Creates the following output

~~~
$ ruby wrapped_exception.rb 
2016-07-29 16:24:21.020279 E [60288:70307486628360 wrapped_exception.rb:40] MyApp -- Failed calling library -- Exception: ALibraryIOException: Failed to write to file
wrapped_exception.rb:25:in `rescue in oh_no'
wrapped_exception.rb:20:in `oh_no'
wrapped_exception.rb:38:in `perform'
wrapped_exception.rb:45:in `<main>'
Cause: IOError: not opened for reading
wrapped_exception.rb:22:in `read'
wrapped_exception.rb:22:in `oh_no'
wrapped_exception.rb:38:in `perform'
wrapped_exception.rb:45:in `<main>'
~~~

Note that the stack trace for the original exception starts after the line containing `Cause: IOError: not opened for reading`.

### [Next: Appenders ==>](appenders.html)
