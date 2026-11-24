require "json"

module SemanticLogger
  module Otlp
    # An encoding of OTLP/HTTP: http/protobuf, the binary Protobuf encoding, or http/json, the JSON
    # encoding (see https://opentelemetry.io/docs/specs/otlp/#otlphttp). It writes a request, given as the
    # Hash of its message (see Protobuf), names its content type, and reads the body of a response.
    #
    # It knows the encodings, and nothing about which message an appender sends: the appender names it.
    class Protocol
      # The encoding of each protocol name, as OTEL_EXPORTER_OTLP_PROTOCOL names it.
      ENCODINGS = {"http/protobuf" => :protobuf, "http/json" => :json}.freeze

      # The protocol when none is given, as the OpenTelemetry specification asks.
      DEFAULT = "http/protobuf".freeze

      CONTENT_TYPES = {protobuf: "application/x-protobuf", json: "application/json"}.freeze

      # Returns [String] the name of the protocol, such as "http/protobuf".
      attr_reader :name

      # Returns [Protocol] the protocol of that name, a String or Symbol, the default for nil. Raises
      # ArgumentError for any other name.
      def self.[](name)
        name = name.nil? ? DEFAULT : name.to_s
        unless ENCODINGS.key?(name)
          names = ENCODINGS.keys.map(&:inspect).join(", ")
          raise(ArgumentError, "protocol: must be one of #{names}, not: #{name.inspect}")
        end

        new(name)
      end

      # Whether there is a protocol of that name.
      def self.known?(name) = ENCODINGS.key?(name)

      def initialize(name)
        @name     = name
        @encoding = ENCODINGS.fetch(name)
      end

      # Whether it writes the binary Protobuf encoding.
      def protobuf? = @encoding == :protobuf

      # Returns [String] the content type of its requests, which it asks for its responses too.
      def content_type = CONTENT_TYPES.fetch(@encoding)

      # Returns [String] the body of a request: the message of that name (see Schema) that the Hash holds.
      def encode(request, message)
        protobuf? ? Protobuf.encode(request, message) : JSON.generate(request)
      end

      # Returns [Hash] the headers that each request is sent with: its Content-Type, and an Accept of
      # the same type, so that a response is written in it too, after those given, such as an Accept of
      # another type, since a response is decoded by its own Content-Type. Raises ArgumentError for a
      # Content-Type given, in any case, of another type, since the body would then not be what it says:
      # the protocol, not a header, chooses the encoding.
      def headers(given)
        given.each_pair do |name, value|
          next unless name.to_s.casecmp?("content-type")
          # Only the media type, without parameters such as "; charset=utf-8".
          next if value.to_s.split(";", 2).first.to_s.strip.casecmp?(content_type)

          raise(ArgumentError,
                "header: #{name} #{value.inspect} does not match the #{self.name} protocol, which sends " \
                "#{content_type}. Choose the encoding with protocol: instead.")
        end
        {"Content-Type" => content_type, "Accept" => content_type}.merge(given)
      end

      # Returns [Hash|nil] the fields of the response body, as the message of that name, decoded by its
      # Content-Type: JSON for a type that names JSON, protobuf for one that names protobuf, and otherwise,
      # such as for no type, or a generic one from a proxy, JSON when the body starts with "{", else the
      # encoding of the protocol. Nil for an empty body, or one that cannot be decoded, for any reason.
      def decode(body, content_type, message)
        return if body.nil? || body.empty?

        fields = json_body?(body, content_type.to_s.downcase) ? JSON.parse(body) : Protobuf.decode(body, message)
        fields if fields.is_a?(Hash)
      rescue StandardError
        nil
      end

      private

      def json_body?(body, content_type)
        return true if content_type.include?("json")
        return false if content_type.include?("protobuf")

        # Not after stripping: the binary encoding of a response starts with "\n", the tag of its field 1.
        body.start_with?("{") || !protobuf?
      end
    end
  end
end
