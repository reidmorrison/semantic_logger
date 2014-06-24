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

```ruby
# config/unicorn.conf.rb
after_fork do |server, worker|
  # Re-open appenders after forking the process
  SemanticLogger.reopen
end
```

### Puma

If running Puma 2 in Clustered mode and you're preloading your application,
add the following to your worker boot code:

```ruby
# config/puma.rb
on_worker_boot do
  # Re-open appenders after forking the process
  SemanticLogger.reopen
end
```

## Auto-detected Frameworks

The following frameworks are automatically detected by the `Rails Semantic Logger` gem,
so the custom code below is only necessary when using Semantic Logger stand-alone:

- Phusion Passenger
- Resque

