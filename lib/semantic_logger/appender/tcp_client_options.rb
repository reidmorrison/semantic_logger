module SemanticLogger
  module Appender
    # The options of Net::TCPClient that the :tcp appender, and the :syslog appender in `tcp_client:`, hand to it,
    # which v6 no longer takes, since it connects with a connection class of its own instead of net_tcp_client.
    module TcpClientOptions
      RETRIES = "v6 does not retry by itself, so it takes only connect_retry_count: 0 and retry_count: 0, which " \
                "keep the worker thread from waiting on retries now too: the appender writes the entry again after " \
                "its back-off instead, see async_max_retries:".freeze

      # Each option that v6 refuses, with why, or what to use instead.
      DEPRECATED = {
        connect_retry_count:    RETRIES,
        connect_retry_interval: "#{RETRIES}, and takes connect_retry_interval: only with connect_retry_count: 0".freeze,
        retry_count:            RETRIES,
        read_timeout:           "the appender never reads",
        buffered:               "v6 writes each entry at once, so it takes only buffered: false",
        close_on_error:         "the connection is closed after any error",
        on_connect:             "it is not called",
        proxy_server:           "the appender does not connect through a proxy"
      }.freeze

      # The values of the deprecated options that v6 still takes, since they are what it does.
      V6_VALUES = {connect_retry_count: 0, retry_count: 0, buffered: false}.freeze

      # The policies that v6 keeps, of those that Net::TCPClient takes.
      POLICIES = %i[ordered random].freeze

      # Reports a deprecation warning that names each of the supplied options that v6 refuses, with why, as the
      # options of the named appender, such as ":tcp". `refused` names other options that v6 refuses for this
      # appender, with why, such as the server of the :syslog appender, which its url gives. An option given as nil
      # is not reported, since v6 ignores it (Net::TCPClient takes nil as the value), nor is one given a value
      # that v6 still takes (see V6_VALUES).
      def self.report_deprecated(options, appender, refused = {})
        reasons = DEPRECATED.merge(refused).reject { |name, _| options[name].nil? || v6_value?(name, options) }
        policy  = options[:policy]
        unless policy.nil? || POLICIES.include?(policy)
          reasons[:policy] = "it takes only :ordered or :random, not #{policy.is_a?(Proc) ? 'a Proc' : policy.inspect}"
        end
        return if reasons.empty?

        Deprecation.warn(
          "The #{appender} appender's #{reasons.keys.map { |name| "#{name}:" }.join(', ')} " \
          "#{reasons.one? ? 'is' : 'are'} deprecated, and v6 raises ArgumentError for " \
          "#{reasons.one? ? 'it' : 'them'}, since it no longer connects with net_tcp_client: " \
          "#{reasons.map { |name, reason| "#{name}: #{reason}" }.join('; ')}."
        )
      end

      # The first version of net_tcp_client that calls measure_* on its logger, rather than the deprecated
      # benchmark_debug and benchmark_error.
      MEASURE_VERSION = Gem::Version.new("2.3.0")

      # The benchmark_* methods that net_tcp_client older than MEASURE_VERSION calls, without the deprecation warning
      # of Base#benchmark_debug and the others. The :tcp and :syslog appenders extend their own internal logger with
      # it, the one they give net_tcp_client, when .report_outdated_gem says it is outdated: it calls them at every
      # connection and write, on the appender's worker thread, where a warning would name no line of the
      # application, and would raise from each write where the application raises deprecation warnings, or log an
      # entry for each write where it logs them.
      module BenchmarkWithoutWarning
        Levels::LEVELS.each do |level|
          define_method(:"benchmark_#{level}") do |message, params = {}, &block|
            public_send(:"measure_#{level}", message, params, &block)
          end
        end
      end

      # Returns whether the installed net_tcp_client is older than MEASURE_VERSION, after reporting a deprecation
      # warning, as the named appender, such as ":tcp", is created, that says to update it.
      def self.report_outdated_gem(appender, version = Net::TCPClient::VERSION)
        return false unless Gem::Version.new(version) < MEASURE_VERSION

        Deprecation.warn(
          "The #{appender} appender uses net_tcp_client #{version}, which calls the deprecated benchmark_* methods " \
          "at every connection and write. Update net_tcp_client to #{MEASURE_VERSION} or later, which calls measure_*."
        )
        true
      end

      # Whether the option has a value that v6 still takes, as the connect_retry_interval: of no connect retries.
      def self.v6_value?(name, options)
        return V6_VALUES[:connect_retry_count] == options[:connect_retry_count] if name == :connect_retry_interval

        V6_VALUES.key?(name) && V6_VALUES[name] == options[name]
      end
      private_class_method :v6_value?
    end
  end
end
