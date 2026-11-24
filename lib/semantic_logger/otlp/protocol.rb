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

      # Returns [Hash|nil] the fields of a response body, the message of that name, with String keys, in
      # the encoding that its content type names, or else in its own; nil when the body is empty, or
      # cannot be read, for any reason.
      def decode(body, content_type, message)
        return if body.nil? || body.empty?

        fields = if content_type.to_s.include?("json") || (!content_type.to_s.include?("protobuf") && !protobuf?)
                   JSON.parse(body)
                 else
                   Protobuf.decode(body, message)
                 end
        fields if fields.is_a?(Hash)
      rescue StandardError
        nil
      end
    end
  end
end
