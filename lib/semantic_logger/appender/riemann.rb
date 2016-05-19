begin
  require "riemann/client"
rescue LoadError
  raise "Gem riemann-client is required for logging to Riemann. Please add the gem 'riemann-client' to your gemfile."
end

# Send log messages to a Riemann server
#
# Example:
#   SemanticLogger.add_appender(appender: :riemann)
class SemanticLogger::Appender::Riemann < SemanticLogger::Subscriber
  attr_reader :riemann_hostname, :riemann_port
  # Create Riemann appender
  #
  # Parameters
  #   riemann_hostname: [String]
  #     Hostname of Riemann server to receive logs
  #     Default: "localhost"
  #
  #   riemann_port: [Fixnum]
  #     Port of Riemann server to receive logs
  #     Default: 5555
  #
  #   protocol: [:tcp | :udp]
  #     Send messages to Riemann server using this protocol
  #
  #   timeout: [Fixnum]
  #     Time in seconds to timeout on sending to server
  #     Default: 5
  #
  #   host: [String]
  #     Set the default hostname to be identified in events
  #     Default: SemanticLogger.host
  #
  #   service: [String]
  #     Set the default service to be identified in events
  #     Default: SemanticLogger.application
  #
  #   ttl: [Fixnum]
  #     Set the TTL field to be sent with the event.
  #     Default: 60
  #
  #   level: [:trace | :debug | :info | :warn | :error | :fatal]
  #     Override the log level for this appender.
  #     This will be included in events as the value of the "state" field.
  #     Default: SemanticLogger.default_level
  #
  #   formatter: [Object | Proc]
  #     An instance of a class that implements #call, or a Proc to be used to format
  #     the output from this subscriber.
  #     NOTE: Not just any formatter will do here, it must return a hash.
  #     Default: Use the built-in 'raw' formatter (See: #call)
  #
  def initialize(options = {}, &block)
    @options = options.dup
    @riemann_host = options.delete(:riemann_hostname) || "localhost"
    @riemann_port = options.delete(:riemann_port) || 5555
    @protocol = options.delete(:protocol) || :tcp
    @timeout = options.delete(:timeout) || 5
    @ttl = options.delete(:ttl) || 60
    @riemann = Riemann::Client.new(host: @riemann_host, port: @riemann_port, timeout: @timeout)

    options[:level] = :error unless options.has_key?(:level)
    super(options, &block)
  end

  # After forking an active process call #reopen to re-open
  # open the handles to resources
  def reopen
    @riemann = Riemann::Client.new(host: @riemann_host, port: @riemann_port, timeout: @timeout)
  end

  def default_formatter
    SemanticLogger::Formatters::Raw.new
  end

  # Returns [Hash] of parameters to send to Riemann
  def call(log, logger)
    h = log.to_h(host, application)
    # Standard keys
    h[:service] = h.delete(:name)
    h[:description] = h.delete(:message)
    h[:time] = h[:time].to_i unless h[:time].nil?
    h[:state] = h.delete(:level).to_s
    h.delete(:tags) if h[:tags].nil?
    h.delete(:metric) if h[:metric].nil?
    h[:ttl] ||= @ttl
    h
  end

  # Send an event to Riemann
  def log(log)
    #return false unless should_log?(log)
    event = formatter.call(log, self)
    event[:should_log] = should_log?(log).to_s

    # For more documentation on sending events to Riemann, see:
    # https://github.com/riemann/riemann-ruby-client
    if @protocol == :tcp
      @riemann.tcp << event
    else
      @riemann.udp << event
    end
    true
  end
end
