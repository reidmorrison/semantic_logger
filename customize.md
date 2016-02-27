---
layout: default
---

## Custom Formatters

The formatting for each appender can be replaced with custom code. To replace the
existing formatter supply a block of code when creating the appender.

The formatter proc receives a single parameter which is the entire `Log Struct`.
For the format of the `Log Struct`, see [Log Struct](log_struct.html)

#### Example: Formatter that just returns the Log Struct

~~~ruby
require 'semantic_logger'

SemanticLogger.default_level = :trace

formatter = Proc.new do |log|
  # This formatter just returns the log struct as a string
  log.inspect
end
SemanticLogger.add_appender(io: STDOUT, formatter: formatter)

logger = SemanticLogger['Hello']
logger.info "Hello World"
~~~
Output:

    #<struct SemanticLogger::Log level=:info, thread_name=70167090649820, name="Hello", message="Hello World", payload=nil, time=2012-10-24 10:09:33 -0400, duration=nil, tags=nil, level_index=2>


#### Example: Replace the default log file formatter

~~~ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace

formatter = Proc.new do |log|
  # Header with date, time, log level and process info
  message = "#{log.formatted_time} #{log.level_to_s} [#{log.process_info}]"

  # Tags
  message << ' ' << log.tags.collect { |tag| "[#{tag}]" }.join(' ') if log.tags && (log.tags.size > 0)

  # Duration
  message << " (#{log.duration_human})" if log.duration

  # Class / app name
  message << " #{log.name}"

  # Log message
  message << " -- #{log.message}" if log.message

  # Payload
  if payload = log.payload_to_s
    message << ' -- ' << payload
  end

  # Exceptions
  if log.exception
    message << " -- Exception: #{log.exception.class}: #{log.exception.message}\n"
    message << log.backtrace_to_s
  end
  message
end

SemanticLogger.add_appender(file_name: 'development.log', formatter: formatter)
~~~

#### Example: Replace the colorized log file formatter

~~~ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace

formatter = Proc.new do |log|
  colors      = SemanticLogger::AnsiColors
  level_color = colors::LEVEL_MAP[log.level]

  # Header with date, time, log level and process info
  message     = "#{log.formatted_time} #{level_color}#{log.level_to_s}#{colors::CLEAR} [#{log.process_info}]"

  # Tags
  message << ' ' << log.tags.collect { |tag| "[#{level_color}#{tag}#{colors::CLEAR}]" }.join(' ') if log.tags && (log.tags.size > 0)

  # Duration
  message << " (#{colors::BOLD}#{log.duration_human}#{colors::CLEAR})" if log.duration

  # Class / app name
  message << " #{level_color}#{log.name}#{colors::CLEAR}"

  # Log message
  message << " -- #{log.message}" if log.message

  # Payload: Colorize the payload if the AwesomePrint gem is loaded
  if log.has_payload?
    payload = log.payload
    message << ' -- ' <<
      if !defined?(AwesomePrint) || !payload.respond_to?(:ai)
        payload.inspect
      else
        payload.ai(@ai_options) rescue payload.inspect
      end
  end

  # Exceptions
  if log.exception
    message << " -- Exception: #{colors::BOLD}#{log.exception.class}: #{log.exception.message}#{colors::CLEAR}\n"
    message << log.backtrace_to_s
  end
  message
end

SemanticLogger.add_appender(file_name: 'development.log', formatter: formatter)
~~~

#### Example: Replacing the format for an active logger, such as in Rails:

This example assumes you have `gem 'rails_semantic_logger'` in your Gemfile.

Create a file called `config/initializers/semantic_logger.rb`:

~~~ruby
# Find file appender:
appender = SemanticLogger.appenders.find{ |a| a.is_a?(SemanticLogger::Appender::File) }

appender.formatter = Proc.new do |log|
  colors      = SemanticLogger::AnsiColors
  level_color = colors::LEVEL_MAP[log.level]

  # Header with date, time, log level and process info
  message     = "#{log.formatted_time} #{level_color}#{log.level_to_s}#{colors::CLEAR} [#{log.process_info}]"

  # Tags
  message << ' ' << log.tags.collect { |tag| "[#{level_color}#{tag}#{colors::CLEAR}]" }.join(' ') if log.tags && (log.tags.size > 0)

  # Duration
  message << " (#{colors::BOLD}#{log.duration_human}#{colors::CLEAR})" if log.duration

  # Class / app name
  message << " #{level_color}#{log.name}#{colors::CLEAR}"

  # Log message
  message << " -- #{log.message}" if log.message

  # Payload: Colorize the payload if the AwesomePrint gem is loaded
  if log.has_payload?
    payload = log.payload
    message << ' -- ' <<
      if !defined?(AwesomePrint) || !payload.respond_to?(:ai)
        payload.inspect
      else
        payload.ai(@ai_options) rescue payload.inspect
      end
  end

  # Exceptions
  if log.exception
    message << " -- Exception: #{colors::BOLD}#{log.exception.class}: #{log.exception.message}#{colors::CLEAR}\n"
    message << log.backtrace_to_s
  end
  message
end
~~~

Modify the code above as needed to meet your requirements.

### [Next: Custom Appenders ==>](custom_appenders.html)
