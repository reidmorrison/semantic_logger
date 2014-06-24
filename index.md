---
layout: default
---

Next generation logging system for Ruby to support highly concurrent, high throughput, low latency systems


Semantic Logger takes logging in Ruby to the next level by adding several new
capabilities to the commonly used Logging API.

### Examples:

```ruby
# Informational logging
logger.info("Calling Supplier")

# Error information
logger.error("Oops external call failed", :result => :failed, :reason_code => -10)

# Debug information
logger.debug { "A total of #{results.inject(0) {|sum, i| i+sum }} were processed" }

# New level for logging low level trace information such as data sent or received
logger.trace { "Raw data received from Supplier: #{raw_response.inspect}" }

# Measure and log how long it takes to execute a block of code
logger.benchmark_info "Calling external interface" do
  # Code to call external service ...
end

# Add tags to every log entry within the code block
logger.tagged(tracking_number) do
  logger.debug("Hello World")
  # ...
end
```
