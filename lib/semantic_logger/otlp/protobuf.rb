module SemanticLogger
  module Otlp
    # Writes and reads the binary Protobuf encoding of an OTLP message, without the google-protobuf gem,
    # from and to the same Hash that the JSON encoding of OTLP is written from (see
    # https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding): its keys are the lowerCamelCase
    # field names, a 64-bit integer may be a decimal String, a double may be "NaN", "Infinity", or
    # "-Infinity", and a trace or span id is hex text (see Schema). So an encoder builds a message once,
    # as data, and either encoding writes it.
    #
    # It knows the wire format, and nothing about OTLP's messages, which Schema describes.
    #
    # Every field present in the Hash is written, even when it holds the default value of its type, as
    # the binary encoding allows, so that a field of a oneof, such as an asInt of 0, is never lost. A
    # nil value is left out. A repeated field of a numeric type is written packed, as proto3 does.
    module Protobuf
      # Raised for a Hash that does not fit its message, such as one with a field the message does not
      # have, or a value of the wrong type. A program error, not one of the data.
      class Error < ArgumentError
      end

      # The wire types.
      VARINT           = 0
      I64              = 1
      LENGTH_DELIMITED = 2
      I32              = 5

      # The wire type of each scalar type of Schema.
      WIRE_TYPES = {
        string: LENGTH_DELIMITED, bytes: LENGTH_DELIMITED, hex_bytes: LENGTH_DELIMITED,
        bool: VARINT, int64: VARINT, uint64: VARINT, uint32: VARINT, int32: VARINT, sint32: VARINT,
        enum: VARINT,
        double: I64, fixed64: I64, sfixed64: I64,
        fixed32: I32
      }.freeze

      UINT64_MASK = (2**64) - 1

      # The text of the doubles that JSON cannot hold as numbers, as the Protobuf JSON mapping writes them.
      DOUBLE_TEXT = {"NaN" => Float::NAN, "Infinity" => Float::INFINITY, "-Infinity" => -Float::INFINITY}.freeze

      # Returns [String] the binary encoding, in ASCII-8BIT, of the message of that name (see Schema)
      # that the Hash holds.
      def self.encode(hash, message)
        write_message(+"".b, hash, message)
      end

      # Returns [Hash] the fields of the message of that name that the binary encoding holds, with String
      # keys, as JSON.parse would return them from the JSON encoding: a 64-bit integer as an Integer, and
      # a field that the message does not have, or of another wire type than it declares, left out. A
      # repeated field is read only when its every value is written apart, not packed.
      #
      # Raises Error when the bytes are not a valid encoding.
      def self.decode(bytes, message)
        fields = Schema.message(message)
        result = {}
        reader = Reader.new(bytes.b)
        until reader.eof?
          key         = reader.varint
          number      = key >> 3
          wire_type   = key & 7
          name, field = fields.find { |_name, candidate| candidate.number == number }
          value       = reader.read(wire_type)
          next unless field && WIRE_TYPES.fetch(field.type, LENGTH_DELIMITED) == wire_type

          result[name.to_s] = decoded_value(value, field)
        end
        result
      end

      # Writes each field of the Hash, of the message of that name, to the buffer. Returns the buffer.
      def self.write_message(buffer, hash, message)
        fields = Schema.message(message)
        raise(Error, "#{message} must be a Hash, not: #{hash.class}") unless hash.is_a?(Hash)

        hash.each_pair do |name, value|
          next if value.nil?

          field = fields[name] || (name.is_a?(String) && fields[name.to_sym])
          raise(Error, "#{message} has no field #{name.inspect}") unless field

          write_field(buffer, field, value)
        end
        buffer
      end

      def self.write_field(buffer, field, value)
        unless field.repeated
          write_value(buffer, field, value)
          return
        end

        raise(Error, "#{field.name} must be an Array, not: #{value.class}") unless value.is_a?(Array)

        if field.message? || WIRE_TYPES[field.type] == LENGTH_DELIMITED
          value.each { |item| write_value(buffer, field, item) }
        elsif !value.empty?
          packed = +"".b
          value.each { |item| write_scalar(packed, field.type, item) }
          write_key(buffer, field.number, LENGTH_DELIMITED)
          write_bytes(buffer, packed)
        end
      end

      def self.write_value(buffer, field, value)
        if field.message?
          write_key(buffer, field.number, LENGTH_DELIMITED)
          write_bytes(buffer, write_message(+"".b, value, field.type))
        else
          write_key(buffer, field.number, WIRE_TYPES.fetch(field.type))
          write_scalar(buffer, field.type, value)
        end
      end

      def self.write_scalar(buffer, type, value)
        case type
        when :string
          write_bytes(buffer, text(value))
        when :bytes
          write_bytes(buffer, value.to_s.b)
        when :hex_bytes
          write_bytes(buffer, hex_bytes(value))
        when :bool
          write_varint(buffer, value ? 1 : 0)
        when :int64, :uint64, :int32, :uint32, :enum
          write_varint(buffer, integer(value) & UINT64_MASK)
        when :sint32
          number = integer(value)
          write_varint(buffer, (number << 1) ^ (number >> 31))
        when :double
          buffer << [double(value)].pack("E")
        when :fixed64
          buffer << [integer(value) & UINT64_MASK].pack("Q<")
        when :sfixed64
          buffer << [integer(value)].pack("q<")
        when :fixed32
          buffer << [integer(value) & 0xFFFF_FFFF].pack("L<")
        else
          raise(Error, "unknown type #{type.inspect}")
        end
      end

      def self.write_key(buffer, number, wire_type)
        write_varint(buffer, (number << 3) | wire_type)
      end

      def self.write_bytes(buffer, bytes)
        write_varint(buffer, bytes.bytesize)
        buffer << bytes
      end

      def self.write_varint(buffer, number)
        while number > 0x7F
          buffer << ((number & 0x7F) | 0x80)
          number >>= 7
        end
        buffer << number
      end

      # Returns [Integer] the Integer, or the Integer of a decimal String, as the JSON encoding writes a
      # 64-bit integer.
      def self.integer(value)
        return value if value.is_a?(Integer)

        Integer(value, 10)
      rescue ArgumentError, TypeError
        raise(Error, "not an integer: #{value.inspect}")
      end

      def self.double(value)
        return value.to_f if value.is_a?(Numeric)

        DOUBLE_TEXT.fetch(value) { raise(Error, "not a double: #{value.inspect}") }
      end

      def self.text(value)
        value = value.is_a?(Symbol) ? value.name : value.to_s
        value.encoding == Encoding::BINARY ? value : value.b
      end

      # Returns [String] the bytes of hex text, such as a trace id.
      def self.hex_bytes(value)
        value = value.to_s
        raise(Error, "not hex text: #{value.inspect}") unless value.match?(/\A(?:\h\h)*\z/)

        [value].pack("H*")
      end

      def self.decoded_value(value, field)
        if field.message?
          decode(value, field.type)
        else
          case field.type
          when :string then value.dup.force_encoding(Encoding::UTF_8)
          when :bool then value != 0
          when :int64, :int32 then value >= 2**63 ? value - (2**64) : value
          when :sint32 then (value >> 1) ^ -(value & 1)
          when :double then value.unpack1("E")
          when :fixed64 then value.unpack1("Q<")
          when :sfixed64 then value.unpack1("q<")
          when :fixed32 then value.unpack1("L<")
          when :hex_bytes then value.unpack1("H*")
          else value
          end
        end
      end

      # Reads the values of the binary encoding of a message, one field at a time.
      class Reader
        def initialize(bytes)
          @bytes    = bytes
          @position = 0
        end

        def eof?
          @position >= @bytes.bytesize
        end

        # Returns the value of the wire type at the position: an Integer for a varint, and the bytes of
        # any other.
        def read(wire_type)
          case wire_type
          when VARINT then varint
          when I64 then take(8)
          when I32 then take(4)
          when LENGTH_DELIMITED then take(varint)
          else raise(Error, "unsupported wire type #{wire_type}")
          end
        end

        def varint
          number = 0
          shift  = 0
          loop do
            raise(Error, "varint too long") if shift > 63

            byte    = take(1).getbyte(0)
            number |= (byte & 0x7F) << shift
            return number if byte < 0x80

            shift += 7
          end
        end

        private

        def take(count)
          raise(Error, "truncated message") if @position + count > @bytes.bytesize

          bytes      = @bytes.byteslice(@position, count)
          @position += count
          bytes
        end
      end

      private_class_method :write_message, :write_field, :write_value, :write_scalar, :write_key, :write_bytes,
                           :write_varint, :integer, :double, :text, :hex_bytes, :decoded_value
    end
  end
end
