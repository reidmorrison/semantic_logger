module SemanticLogger
  module Appender
    # The options of Net::TCPClient that the :tcp appender, and the :syslog appender in `tcp_client:`, hand to it,
    # which v6 no longer takes, since it connects with a connection class of its own instead of net_tcp_client.
    module TcpClientOptions
      RETRIES = "the appender writes again after its back-off instead, see async_max_retries:".freeze

      # Each option that v6 refuses, with why, or what to use instead.
      DEPRECATED = {
        connect_retry_count:    RETRIES,
        connect_retry_interval: RETRIES,
        retry_count:            RETRIES,
        read_timeout:           "the appender never reads",
        buffered:               "the appender writes each entry at once",
        close_on_error:         "the connection is closed after any error",
        on_connect:             "it is not called",
        proxy_server:           "the appender does not connect through a proxy"
      }.freeze

      # The policies that v6 keeps, of those that Net::TCPClient takes.
      POLICIES = %i[ordered random].freeze

      # Reports a deprecation warning that names each of the supplied options that v6 refuses, with why, as the
      # options of the named appender, such as ":tcp". `ignored` names options that the appender itself takes
      # elsewhere, with why, such as the server of the :syslog appender, which its url gives. An option given as
      # nil sets nothing, so it is not reported.
      def self.report_deprecated(options, appender, ignored = {})
        reasons = DEPRECATED.merge(ignored).reject { |name, _| options[name].nil? }
        policy  = options[:policy]
        unless policy.nil? || POLICIES.include?(policy)
          reasons[:policy] = "it takes only :ordered or :random, not #{policy.inspect}"
        end
        return if reasons.empty?

        Deprecation.warn(
          "The #{appender} appender's #{reasons.keys.map { |name| "#{name}:" }.join(', ')} " \
          "#{reasons.one? ? 'is' : 'are'} deprecated, and v6 raises ArgumentError for " \
          "#{reasons.one? ? 'it' : 'them'}, since it no longer connects with net_tcp_client: " \
          "#{reasons.map { |name, reason| "#{name}: #{reason}" }.join('; ')}."
        )
      end
    end
  end
end
