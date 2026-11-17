module SemanticLogger
  module Formatters
    # The host name and the application name (the TAG) that the formatters building a remote syslog
    # packet (Syslog and SyslogCee) write in its header.
    #
    # The syslog_protocol gem, following RFC 3164, allows only printable ASCII characters other than
    # the space (33 to 126) in either, and up to 32 in the TAG, and raises for any other, which made
    # the formatter lose every entry, such as for an application named "Café", or with a name over
    # 32 characters. So the other characters are left out, as the spaces always were from the TAG,
    # and the TAG is cut to 32 characters. When no character is left, "localhost" or
    # "SemanticLogger" is written instead.
    #
    # Each is worked out once, and again only when the host or application name changes.
    module SyslogHeader
      # The most characters that the TAG of a syslog header can hold.
      MAX_TAG_SIZE = 32

      # Written in place of a host name with no character left.
      DEFAULT_HOSTNAME = "localhost".encode(Encoding::US_ASCII).freeze

      # Written in place of an application name with no character left.
      DEFAULT_TAG = "SemanticLogger".encode(Encoding::US_ASCII).freeze

      private

      # Returns [String] the host name as the syslog header holds it.
      def syslog_hostname(host) = syslog_header_field(:hostname, host, DEFAULT_HOSTNAME)

      # Returns [String] the application name as the TAG of the syslog header holds it.
      def syslog_tag(application) = syslog_header_field(:tag, application, DEFAULT_TAG, MAX_TAG_SIZE)

      # Returns [String] the field cleaned (see SyslogHeader), frozen, from the cache when the text
      # is the one it was worked out from, or holds the same characters, such as an appender's own
      # name that was changed in place, which the cache keeps a frozen copy of. Any other object,
      # other than a Symbol, is read as its #to_s first, so that one changed in place is noticed too.
      def syslog_header_field(field, text, fallback, max_size = nil)
        text   = text.to_s unless text.is_a?(String) || text.is_a?(Symbol)
        cached = (@syslog_header_fields ||= {})[field]
        return cached.last if cached && (cached.first.equal?(text) || cached.first == text)

        value = text.to_s.b.delete("^\x21-\x7E")
        value = value[0, max_size] if max_size
        value = value.empty? ? fallback : value.force_encoding(Encoding::US_ASCII).freeze
        @syslog_header_fields[field] = [text.is_a?(String) && !text.frozen? ? text.dup.freeze : text, value]
        value
      end
    end
  end
end
