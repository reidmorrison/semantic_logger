begin
  require 'splunk-sdk-ruby'
rescue LoadError
  raise 'Gem splunk-sdk-ruby is required for logging to Splunk. Please add the gem "splunk-sdk-ruby" to your Gemfile.'
end

# Splunk log appender.
#
# Use the official splunk gem to log messages to Splunk.
#
# Example
#   SemanticLogger.add_appender(
#     appender: :splunk,
#     username: 'username',
#     password: 'password',
#     host:     'localhost',
#     port:     8089,
#     scheme:   :https,
#     index:    'main'
#   )
class SemanticLogger::Appender::Splunk < SemanticLogger::Appender::Base
  attr_reader :config, :index, :service, :service_index

  # Write to Splunk.
  #
  # Parameters
  #   :username [String]
  #     User name to log into splunk with.
  #     Not required if :token has been supplied.
  #
  #   :password [String]
  #     Password to log into splunk with.
  #     Not required if :token has been supplied.
  #
  #   :token
  #     Supply a preauthenticated Splunk token instead of username and password.
  #     Not required if username and password are supplied.
  #
  #   :host [String]
  #      Splunk host name.
  #      Default: 'localhost'
  #
  #   :port [Integer]
  #      The Splunk management port.
  #      Default: 8089
  #
  #   :scheme [Symbol]
  #     Either :https or :http
  #     Default: :https
  #
  #   :index [String]
  #      Splunk index to use.
  #      Default: 'main'
  #
  #   :namespace [Namespace]
  #      Application namespace instance.
  #
  #   :ssl_client_cert [OpenSSL::X509::Certificate]
  #     Client certificate.
  #
  #   :ssl_client_key [OpenSSL::PKey::RSA | OpenSSL::PKey::DSA]
  #     Client key.
  #
  #   level: [:trace | :debug | :info | :warn | :error | :fatal]
  #     Override the log level for this appender.
  #     Default: SemanticLogger.default_level
  #
  #   formatter: [Object|Proc]
  #     An instance of a class that implements #call, or a Proc to be used to format
  #     the output from this appender
  #     Default: Use the built-in formatter (See: #call)
  #
  #   filter: [Regexp|Proc]
  #     RegExp: Only include log messages where the class name matches the supplied.
  #     regular expression. All other messages will be ignored.
  #     Proc: Only include log messages where the supplied Proc returns true
  #           The Proc must return true or false.
  def initialize(options, _deprecated_level = nil, &block)
    @config         = options.dup
    @config[:level] = _deprecated_level if _deprecated_level
    @index          = @config.delete(:index) || 'main'

    options = {
      level:     @config.delete(:level) || :error,
      formatter: @config.delete(:formatter),
      filter:    @config.delete(:filter)
    }

    reopen

    # Pass on the level and custom formatter if supplied
    super(options, &block)
  end

  # After forking an active process call #reopen to re-open
  # open the handles to resources
  def reopen
    # Connect to splunk. Connect is a synonym for creating a Service by hand and calling login.
    self.service       = Splunk::connect(config)

    # The index we are logging to
    self.service_index = service.indexes[index]
  end

  # Log the message to Splunk
  def log(log)
    return false unless should_log?(log)

    service_index.submit(log.message, formatter.call(log, self))
    true
  end

  # Returns [String] JSON to send to Splunk
  # For splunk format requirements see:
  #   http://dev.splunk.com/view/event-collector/SP-CAAAE6P
  def call(log, _logger)
    h = log.to_h
    h.delete(:message)
    h.delete(:application)
    h.delete(:host)
    h.delete(:time)
    h
  end
end
