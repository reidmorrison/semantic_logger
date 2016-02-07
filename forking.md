---
layout: default
---

## Process Forking

In Ruby it is common for Frameworks such Puma and Resque to fork a copy of the
process so that it can run independently from the parent process.

After a process has forked `SemanticLogger.reopen` must be called to re-open
files and re-start the appender thread. Otherwise, logging will appear to stop.

Below are some of the common frameworks that use process forking and what you need
to do so that Semantic Logger can continue to function after a fork:

### Unicorn

With Unicorn, add the following code to you Unicorn configuration:

~~~ruby
# config/unicorn.conf.rb
after_fork do |server, worker|
  # Re-open appenders after forking the process
  SemanticLogger.reopen
end
~~~

### Puma

If running Puma 2 in Clustered mode and you're preloading your application,
add the following to your worker boot code:

~~~ruby
# config/puma.rb
on_worker_boot do
  # Re-open appenders after forking the process
  SemanticLogger.reopen
end
~~~

### Auto-detected Frameworks

The following frameworks are automatically detected by the `Rails Semantic Logger` gem,
so the custom code below is only necessary when using Semantic Logger stand-alone:

- Phusion Passenger
- Resque
- Spring

Add the following code only if Rails Semantic Logger gem is not being used and
you are using these frameworks:

~~~ruby
# Passenger provides the :starting_worker_process event for executing
# code after it has forked, so we use that and reconnect immediately.
if defined?(PhusionPassenger)
  PhusionPassenger.on_event(:starting_worker_process) do |forked|
    ::SemanticLogger.reopen if forked
  end
end

# Re-open appenders after Resque has forked a worker
if defined?(Resque)
  Resque.after_fork { |job| ::SemanticLogger.reopen }
end

# Re-open appenders after Spring has forked a process
if defined?(Spring)
  Spring.after_fork { |job| ::SemanticLogger.reopen }
end
~~~

### [Next: Log Rotation ==>](log_rotation.html)
