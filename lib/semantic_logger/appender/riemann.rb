begin
  require "riemann-ruby-experiments"
rescue LoadError
  raise "Gem riemann-ruby-experiments is required for logging to Riemann. Please add the gem 'riemann-ruby-experiments' to your gemfile."
end

# Send log messages to a Riemann server
#
# Example:
#   SemanticLogger.add_appender(appender: :riemann)
class SemanticLogger::Appender::Riemann < SemanticLogger::Subscriber
  # Read up on Riemann::Experiment::Client and Net::TCPClient before tweaking this!
  attr_accessor :riemann_opts

  # Create Riemann appender
  #
  # Parameters
  #   riemann_server: [String]
  #     Hostname and port of Riemann server to receive logs
  #     Default: "localhost:5555"
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
  #     Default: unincluded in message
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
  #  Other options with names that begin with "riemann_socket_" will be given
  #  the remainder of the name as corresponding parameters to Net::TCPClient.new().
  #  See the documentation there for options involving timeouts, etc.
  def initialize(options = {}, &block)
    @riemann_opts = {}
    @riemann_opts[:server] = options.delete(:riemann_server) || "localhost:5555"
    @riemann_opts[:host]    = options.delete(:host) || SemanticLogger.host
    @riemann_opts[:service] = options.delete(:service) || SemanticLogger.application
    if options[:ttl]
      @riemann_opts[:ttl] = options.delete(:ttl)
    end
    rx = /^riemann_socket_/
    options.select {|k, v| rx.match(k.to_s) }.each {|k, v|
      m = rx.match(k.to_s)
      options.delete(k)
      if m
        @riemann_opts[m.post_match.to_sym] = v
      end
    }

    @options = options.dup
    @riemann = Riemann::Experiment::Client.new(@riemann_opts)

    options[:level] = :info unless options.has_key?(:level)
    super(options, &block)
  end

  # After forking an active process call #reopen to re-open
  # open the handles to resources
  def reopen
    @riemann = Riemann::Experiment::Client.new(@riemann_opts)
  end

  def default_formatter
    SemanticLogger::Formatters::Raw.new
  end

  # Returns [Hash] of parameters to send to Riemann
  def call(log, logger)
    h = log.to_h(host, application)
    # Standard keys
    h[:service] = h.delete(:name) || @riemann_opts[:service]
    h[:time] = h[:time].to_i unless h[:time].nil? # will be included by client if not.
    h[:state] = h.delete(:level).to_s
    h[:payload] = h[:payload].to_s unless h[:payload].nil?
    h[:exception] = h[:exception].to_s unless h[:exception].nil?
    h[:backtrace] = h[:backtrace].to_s unless h[:backtrace].nil?

    tags = h.delete(:tags) || []

    if h[:duration_ms]
      h[:duration] = h[:duration_ms]
      h.delete(:duration_ms)
    end

    # If you're changing this, remember that:
    # to SemanticLogger, the value of 'metric' is a string, the name of the metric.
    # to Riemann, the value of 'metric' is a number.
    #
    if log.message&.is_a?(Hash) # A metric counter
      description = log.message[:message]
      h[:service] = [h[:service], log.message[:metric]].join("/")
      tags.push("counter")
      if log.message[:metric_amount]
        h[:metric] = log.message[:metric_amount]
      end
      h.delete(:message)
    else
      description = h.delete(:message)
      if !h[:duration].nil? # A metric, but not a metric conuter.
        h[:service] = [h[:service], h[:metric]].join("/")
        h[:metric] = h[:duration_ms] || h[:duration]
        h.delete(:duration)
        h.delete(:duration_ms)
        tags.push("metric")
      end
    end

    h[:tags] = tags unless tags.length == 0
    h[:description] = description
    h
  end

  # Send an event to Riemann
  def log(log)
    return false unless should_log?(log)
    event = formatter.call(log, self)

    # For more documentation on sending events to Riemann, see:
    # https://github.com/riddochc/riemann-ruby-experiments
    @riemann.add_event(event)
    @riemann.send_message(ok: true)
  end
end
