require "uri"

module SemanticLogger
  module Metric
    class Otlp < SemanticLogger::Appender::Http
      # The OpenTelemetry environment variables that configure an OTLP metric exporter: reads them,
      # parses their values as the OpenTelemetry specification describes, and reports, on the logger it
      # is given, a value that it cannot use and so ignores. Otlp decides what each one applies to, and
      # which of its own options win over them.
      #
      # A variable of the metrics signal, such as OTEL_EXPORTER_OTLP_METRICS_HEADERS, replaces its
      # generic one, such as OTEL_EXPORTER_OTLP_HEADERS, as a whole. A variable that is empty, or holds
      # only blanks, counts as not set. Each value is parsed, and any problem with it reported, once,
      # when it is first asked for.
      #
      # See https://opentelemetry.io/docs/specs/otel/protocol/exporter/ and
      # https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/
      class Environment
        # A header name: an HTTP token (RFC 9110).
        HEADER_NAME = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

        # Characters that a header value cannot hold (RFC 9110): controls other than a tab.
        HEADER_VALUE_INVALID = /[\x00-\x08\x0A-\x1F\x7F]/

        # The compression of each value of OTEL_EXPORTER_OTLP_COMPRESSION that it knows: true for gzip.
        COMPRESSIONS = {"gzip" => true, "none" => false}.freeze

        # Milliseconds in a second, to convert the timeouts.
        MILLISECONDS = 1000.0

        # Parameters:
        #   logger: [SemanticLogger::Logger]
        #     Reports a value that cannot be used, never with a header value, which may hold credentials.
        def initialize(logger)
          @logger = logger
        end

        # Returns [String|nil] the full url to post the metrics to.
        def endpoint
          value("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT")
        end

        # Returns [String|nil] the base url of the OTLP/HTTP receiver.
        def base_url
          value("OTEL_EXPORTER_OTLP_ENDPOINT")
        end

        # Returns [String|nil] the name of the service.
        def service_name
          value("OTEL_SERVICE_NAME")
        end

        # Returns [Hash<String, String>] the headers to send with each request, none when not set. An
        # entry that is not a valid `name=value`, once percent-decoded, is left out and reported.
        def headers
          return @headers if defined?(@headers)

          name, text = signal_value("HEADERS")
          @headers   = text ? parse_headers(name, text).freeze : {}.freeze
        end

        # Returns [true|false] whether a valid timeout is set (see #timeout).
        def timeout?
          !timeout_setting.empty?
        end

        # Returns [Float|nil] the timeout in seconds, nil for no limit, given in milliseconds, 0 meaning no
        # limit. A value that is not a whole number of milliseconds is ignored and reported.
        def timeout
          timeout_setting.first
        end

        # Returns [true|false|nil] whether to compress the requests with gzip, nil when not set. A value
        # other than "gzip" or "none", in any case, is ignored and reported.
        def compress
          return @compress if defined?(@compress)

          name, text = signal_value("COMPRESSION")
          @compress  = text && parse_compression(name, text)
        end

        # Returns [Hash<String, String>] the attributes of the resource, none when not set. When any entry
        # is not a valid `key=value`, once percent-decoded, the whole value is ignored and reported, as the
        # OpenTelemetry specification of the resource SDK asks.
        def resource_attributes
          return @resource_attributes if defined?(@resource_attributes)

          text                 = value("OTEL_RESOURCE_ATTRIBUTES")
          @resource_attributes = ((text && parse_resource_attributes(text)) || {}).freeze
        end

        private

        attr_reader :logger

        # Returns [Array] the timeout in seconds, nil for no limit, in a one element Array; empty when not
        # set, or invalid.
        def timeout_setting
          @timeout_setting ||=
            begin
              name, text = signal_value("TIMEOUT")
              text ? parse_timeout(name, text) : []
            end
        end

        def parse_timeout(name, text)
          text = text.strip
          unless text.match?(/\A\d+\z/)
            logger.warn("Ignoring #{name}=#{text.inspect}: not a whole number of milliseconds")
            return []
          end

          milliseconds = Integer(text, 10)
          [milliseconds.zero? ? nil : milliseconds / MILLISECONDS]
        end

        def parse_compression(name, text)
          compress = COMPRESSIONS[text.strip.downcase]
          return compress unless compress.nil?

          logger.warn("Ignoring #{name}=#{text.strip.inspect}: the compression is neither gzip nor none")
          nil
        end

        # The entries that are not valid are reported by their position only, since their text may be or
        # hold a credential.
        def parse_headers(name, text)
          headers = {}
          invalid = []
          each_entry(text) do |key, value, position|
            if key&.match?(HEADER_NAME) && !value.match?(HEADER_VALUE_INVALID)
              headers[key] = value
            else
              invalid << position
            end
          end
          unless invalid.empty?
            logger.warn("Ignoring the entries of #{name} at position(s) #{invalid.join(', ')}: not a valid name=value")
          end
          headers
        end

        def parse_resource_attributes(text)
          attributes = {}
          invalid    = []
          each_entry(text) do |key, value, position|
            if key.nil? || key.empty?
              invalid << position
            else
              attributes[key] = value
            end
          end
          return attributes if invalid.empty?

          logger.warn(
            "Ignoring OTEL_RESOURCE_ATTRIBUTES: the entries at position(s) #{invalid.join(', ')} " \
            "are not a valid key=value"
          )
          nil
        end

        # Yields the key and value of each comma-separated `key=value` entry of the text, trimmed and
        # percent-decoded, and its position, counted from 1, skipping blank entries. The key is nil when
        # the entry has no "=", or does not percent-decode to valid UTF-8; the value is then "".
        def each_entry(text)
          text.split(",").each_with_index do |entry, index|
            next if entry.strip.empty?

            key, separator, value = entry.partition("=")
            key   = decode(key.strip)
            value = decode(value.strip)
            key   = nil if separator.empty? || value.nil?
            yield key, value || "", index + 1
          end
        end

        # Returns [String|nil] the text percent-decoded, nil when it is not valid percent-encoded UTF-8.
        def decode(text)
          decoded = URI.decode_uri_component(text)
          decoded if decoded.valid_encoding?
        rescue ArgumentError
          nil
        end

        # Returns [Array<String>] the name and value of the metrics variable of the setting, or else of
        # its generic one; a nil value when neither is set.
        def signal_value(setting)
          name = "OTEL_EXPORTER_OTLP_METRICS_#{setting}"
          text = value(name)
          return [name, text] if text

          name = "OTEL_EXPORTER_OTLP_#{setting}"
          [name, value(name)]
        end

        # Returns [String|nil] the value of the environment variable, nil when it is not set or blank.
        def value(name)
          text = ENV.fetch(name, nil)
          text unless text.nil? || text.strip.empty?
        end
      end
    end
  end
end
