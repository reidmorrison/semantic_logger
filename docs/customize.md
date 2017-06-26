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
~~~

Create a custom formatter:
~~~ruby
class MyFormatter < SemanticLogger::Formatters::Default
  # Return the complete log level name in uppercase
  def level
    log.level.upcase
  end
end
~~~

Specify the formatter when creating the appender:
~~~ruby
SemanticLogger.add_appender(file_name: 'development.log', formatter: MyFormatter.new)
~~~

Example usage:
~~~ruby
Rails.logger.info "Hello World"

# => 2017-04-05 01:05:52.868286 INFO [13143:70216759638540 (irb):11] Rails -- Hello World
~~~

See [SemanticLogger::Formatters::Default](https://github.com/rocketjob/semantic_logger/blob/master/lib/semantic_logger/formatters/default.rb) for all the methods that can be replaced to customize the output.

#### Example: Replace the colorized log file formatter

~~~ruby
require 'semantic_logger'
SemanticLogger.default_level = :trace
~~~

Create a custom formatter:
~~~ruby
class MyFormatter < SemanticLogger::Formatters::Color
  # Return the complete log level name in uppercase
  def level
    "#{color}log.level.upcase#{clear}"
  end
end
~~~

Specify the formatter when creating the appender:
~~~ruby
SemanticLogger.add_appender(file_name: 'development.log', formatter: MyFormatter.new)
~~~

Example usage:
~~~ruby
Rails.logger.info "Hello World"

# => 2017-04-05 01:05:52.868286 INFO [13143:70216759638540 (irb):11] Rails -- Hello World
~~~

See [SemanticLogger::Formatters::Color](https://github.com/rocketjob/semantic_logger/blob/master/lib/semantic_logger/formatters/color.rb) for all the methods that can be replaced to customize the output.

#### Example: Replacing the format for an active logger, such as in Rails:

This example assumes you have `gem 'rails_semantic_logger'` in your Gemfile.

Create a file called `config/initializers/semantic_logger.rb`:

~~~ruby
# Find file appender:
appender = SemanticLogger.appenders.find{ |a| a.is_a?(SemanticLogger::Appender::File) }

appender.formatter = MyFormatter.new
~~~

### [Next: Custom Appenders ==>](custom_appenders.html)
