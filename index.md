---
layout: default
---

Next generation logging system for Ruby to support highly concurrent, high throughput, low latency systems


Semantic Logger takes logging in Ruby to the next level by adding several new
capabilities to the commonly used Logging API.

### Example:

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
logger.trace { "Raw data received from Supplier: #{raw_response.inspect}" }

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