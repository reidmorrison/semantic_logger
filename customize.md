---
layout: default
---

### Custom Formatters

The formatting for each appender can be replaced with custom code. To replace the
existing formatter supply a block of code when creating the appender.

The formatter proc receives a single parameter which is the entire `Log Struct`.
For the format of the `Log Struct`, see [Log Struct](log_struct.html)

Example: Formatter that just returns the Log Struct

```ruby
require 'semantic_logger'

SemanticLogger.default_level = :trace

SemanticLogger.add_appender(STDOUT) do |log|
 # This formatter just returns the log struct as a string
  log.inspect
end

logger = SemanticLogger['Hello']
logger.info "Hello World"
```
Output:

    #<struct SemanticLogger::Base::Log level=:info, thread_name=70167090649820, name="Hello", message="Hello World", payload=nil, time=2012-10-24 10:09:33 -0400, duration=nil, tags=nil, level_index=2>


Example: Replace the default log file formatter

```ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace

SemanticLogger.add_appender('development.log') do |log|
  tags = log.tags.collect { |tag| "[#{tag}]" }.join(' ') + ' ' if log.tags && (log.tags.size > 0)

  message = log.message.to_s.dup
  message << ' -- ' << log.payload.inspect unless log.payload.nil? || log.payload.empty?
  message << ' -- Exception: ' << "#{log.exception.class}: #{log.exception.message}\n#{(log.exception.backtrace || []).join("\n")}" if log.exception

  duration_str = log.duration ? "(#{'%.1f' % log.duration}ms) " : ''

  "#{SemanticLogger::Appender::Base.formatted_time(log.time)} #{log.level.to_s[0..0].upcase} [#{$$}:#{'%.50s' % log.thread_name}] #{tags}#{duration_str}#{log.name} -- #{message}"
end
```

Example: Replace the colorized log file formatter

```ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace

SemanticLogger.add_appender('development.log') do |log|
  colors = SemanticLogger::Appender::AnsiColors
  tags   = log.tags.collect { |tag| "[#{colors::CYAN}#{tag}#{colors::CLEAR}]" }.join(' ') + ' ' if log.tags && (log.tags.size > 0)

  message = log.message.to_s.dup
  unless log.payload.nil? || log.payload.empty?
    payload = log.payload
    payload = (defined?(AwesomePrint) && payload.respond_to?(:ai)) ? payload.ai(multiline: false) : payload.inspect
    message << ' -- ' << payload
  end
  message << ' -- Exception: ' << "#{colors::BOLD}#{log.exception.class}: #{log.exception.message}#{colors::CLEAR}\n#{(log.exception.backtrace || []).join("\n")}" if log.exception

  duration_str = log.duration ? "(#{colors::BOLD}#{'%.1f' % log.duration}ms#{colors::CLEAR}) " : ''

  level_color =
    case log.level
    when :trace
      colors::MAGENTA
    when :debug
      colors::GREEN
    when :info
      colors::CYAN
    when :warn
      colors::BOLD
    when :error, :fatal
      colors::RED
    end

  "#{SemanticLogger::Appender::Base.formatted_time(log.time)} #{level_color}#{colors::BOLD}#{log.level.to_s[0..0].upcase}#{colors::CLEAR} [#{$$}:#{'%.30s' % log.thread_name}] #{tags}#{duration_str}#{level_color}#{log.name}#{colors::CLEAR} -- #{message}"
end
```

Example: Replace the default MongoDB formatter

```ruby
# Log to MongoDB and supply a custom document formatter
mongodb_appender = SemanticLogger::Appender::MongoDB.new(
  :db              => Cache::Work.db,
  :collection_size => 25.gigabytes
) do |log|
    # Return a document (Hash) of the data to be saved to MongoDB
    document = {
      :time        => log.time,
      :host_name   => SemanticLogger::Appender::MongoDB.host_name,
      :pid         => $PID,
      :thread_name => log.thread_name,
      :name        => log.name,
      :level       => log.level,
      :level_index => log.level_index,
    }
    document[:application] = 'MyApplication'
    document[:message]     = SemanticLogger::Appender::MongoDB.strip_colorizing(log.message) if log.message
    document[:duration]    = log.duration if log.duration
    document[:tags]        = log.tags if log.tags && (log.tags.size > 0)
    document[:payload]     = log.payload if log.payload
    document[:exception]   = {
      :name        => log.exception.class.name,
      :message     => log.exception.message,
      :stack_trace => log.exception.backtrace
    } if log.exception
    document
end
SemanticLogger.add_appender(mongodb_appender)
```

### [Next: Custom Appenders ==>](custom_appenders.html)
