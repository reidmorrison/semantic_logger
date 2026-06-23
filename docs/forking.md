---
layout: default
---

## Process Forking

In Ruby it is common for Frameworks such Puma and Resque to fork a copy of the
process so that it can run independently from the parent process.

After a process has forked, appenders must be re-opened to re-open files and
re-start the appender thread. Otherwise, logging will appear to stop.

### Automatic reopen on fork (default)

As of v5, Semantic Logger does this for you. It installs a `Process._fork` hook
(Ruby 3.1 and later) that calls `SemanticLogger.reopen` in the child process after
`fork`, `Process.daemon`, `IO.popen`, `Kernel#system`, and backticks. This covers
all forking frameworks (Puma, Unicorn, Resque, Spring, Phusion Passenger, parallel
tests, etc.) without any additional code.

`SemanticLogger.reopen` no-ops if it has already run in the current process after a
fork, so it is safe even if something else also calls it. If you need to reopen
within the same process (for example after an external log rotation that did not
fork), call `SemanticLogger.reopen(force: true)` to bypass that guard.

### Opting out

To restore full manual control, disable the automatic hook during application boot
and call `SemanticLogger.reopen` yourself after each fork:

~~~ruby
SemanticLogger.reopen_on_fork = false
~~~

You might opt out if, for example, another library also forks in ways you do not
want to trigger a reopen, or you need to control exactly when the appender thread
is restarted.

### [Next: Log Rotation ==>](log_rotation.html)
