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
    # Each is worked out once, and again only when the host or application name is replaced.
    module SyslogHeader
      # The most characters that the TAG of a syslog header can hold.
      MAX_TAG_SIZE = 32

      private

      # Returns [String] the host name as the syslog header holds it.
      def syslog_hostname(host) = syslog_header_field(:hostname, host, "localhost")

      # Returns [String] the application name as the TAG of the syslog header holds it.
      def syslog_tag(application) = syslog_header_field(:tag, application, "SemanticLogger", MAX_TAG_SIZE)

      def syslog_header_field(field, text, fallback, max_size = nil)
        cached = (@syslog_header_fields ||= {})[field]
        return cached.last if cached&.first.equal?(text)

        value = text.to_s.b.delete("^\x21-\x7E")
        value = value[0, max_size] if max_size
        value = fallback if value.empty?
        @syslog_header_fields[field] = [text, value.force_encoding(Encoding::US_ASCII)]
        value
      end
    end
  end
end
