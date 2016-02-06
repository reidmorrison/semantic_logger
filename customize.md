---
layout: default
---

### Custom Formatters

The formatting for each appender can be replaced with custom code. To replace the
existing formatter supply a block of code when creating the appender.

The formatter proc receives a single parameter which is the entire `Log Struct`.
For the format of the `Log Struct`, see [Log Struct](log_struct.html)

#### Example: Formatter that just returns the Log Struct

~~~ruby
require 'semantic_logger'

SemanticLogger.default_level = :trace

SemanticLogger.add_appender(STDOUT) do |log|
 # This formatter just returns the log struct as a string
  log.inspect
end

logger = SemanticLogger['Hello']
logger.info "Hello World"
~~~
Output:

    #<struct SemanticLogger::Log level=:info, thread_name=70167090649820, name="Hello", message="Hello World", payload=nil, time=2012-10-24 10:09:33 -0400, duration=nil, tags=nil, level_index=2>


#### Example: Replace the default log file formatter

~~~ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace

SemanticLogger.add_appender('development.log') do |log|
  # Header with date, time, log level and process info
  entry = "#{log.formatted_time} #{log.level_to_s} [#{log.process_info}]"

  # Tags
  entry << ' ' << log.tags.collect { |tag| "[#{tag}]" }.join(' ') if log.tags && (log.tags.size > 0)

  # Duration
  entry << " (#{log.duration_human})" if log.duration

  # Class / app name
  entry << " #{log.name}"

  # Log message
  entry << " -- #{log.message}" if log.message

  # Payload
  unless log.payload.nil? || (log.payload.respond_to?(:empty?) && log.payload.empty?)
    entry << ' -- ' << log.payload.inspect
  end

  # Exceptions
  log.each_exception do |exception, i|
    entry << (i == 0 ? ' -- Exception: ' : "\nCause: ")
    entry << "#{exception.class}: #{exception.message}\n#{(exception.backtrace || []).join("\n")}"
  end
  entry
end
~~~

#### Example: Replace the colorized log file formatter

~~~ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace

SemanticLogger.add_appender('development.log') do |log|
  colors      = SemanticLogger::Appender::AnsiColors
  level_color = colors::LEVEL_MAP[log.level]

  # Header with date, time, log level and process info
  entry       = "#{log.formatted_time} #{level_color}#{log.level_to_s}#{colors::CLEAR} [#{log.process_info}]"

  # Tags
  entry << ' ' << log.tags.collect { |tag| "[#{level_color}#{tag}#{colors::CLEAR}]" }.join(' ') if log.tags && (log.tags.size > 0)

  # Duration
  entry << " (#{colors::BOLD}#{log.duration_human}#{colors::CLEAR})" if log.duration

  # Class / app name
  entry << " #{level_color}#{log.name}#{colors::CLEAR}"

  # Log message
  entry << " -- #{log.message}" if log.message

  # Payload
  if payload = log.payload_to_s(true)
    entry << ' -- ' << payload
  end

  # Exceptions
  if log.exception
    entry << " -- Exception: #{colors::BOLD}#{log.exception.class}: #{log.exception.message}#{colors::CLEAR}\n"
    entry << log.backtrace_to_s
  end
  entry
end
~~~

#### Example: Replacing the format for an active logger, such as in Rails:

This example assumes you have `gem 'rails_semantic_logger'` in your Gemfile.

Create a file called `config/initializers/semantic_logger.rb`:

~~~ruby
# Find file appender:
appender = SemanticLogger.appenders.find{ |a| a.is_a?(SemanticLogger::Appender::File) }
appender.formatter = Proc.new do |log|
  colors      = SemanticLogger::Appender::AnsiColors
  level_color = colors::LEVEL_MAP[log.level]

  # Header with date, time, log level and process info
  entry       = "#{log.formatted_time} #{level_color}#{log.level_to_s}#{colors::CLEAR} [#{log.process_info}]"

  # Tags
  entry << ' ' << log.tags.collect { |tag| "[#{level_color}#{tag}#{colors::CLEAR}]" }.join(' ') if log.tags && (log.tags.size > 0)

  # Duration
  entry << " (#{colors::BOLD}#{log.duration_human}#{colors::CLEAR})" if log.duration

  # Class / app name
  entry << " #{level_color}#{log.name}#{colors::CLEAR}"

  # Log message
  entry << " -- #{log.message}" if log.message

  # Payload
  if payload = log.payload_to_s(true)
    entry << ' -- ' << payload
  end

  # Exceptions
  if log.exception
    entry << " -- Exception: #{colors::BOLD}#{log.exception.class}: #{log.exception.message}#{colors::CLEAR}\n"
    entry << log.backtrace_to_s
  end
  entry
end
~~~

Modify the code above as needed to meet your requirements.

### [Next: Custom Appenders ==>](custom_appenders.html)
