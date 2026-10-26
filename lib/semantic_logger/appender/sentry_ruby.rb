begin
  require "sentry-ruby"
rescue LoadError
  raise LoadError, 'Gem sentry-ruby is required for logging purposes. Please add the gem "sentry-ruby" to your Gemfile.'
end

# Send log messages to sentry
#
# Example:
#   SemanticLogger.add_appender(appender: :sentry_ruby)
#
module SemanticLogger
  module Appender
    class SentryRuby < SemanticLogger::Subscriber
      # Keys of the named tags or payload that set the Sentry user, mapped to its fields.
      USER_KEYS = {user_id: :id, username: :username, user_email: :email, ip_address: :ip_address}.freeze

      # The types of value taken from the payload for a field of the Sentry user.
      USER_VALUE_TYPES = [String, Symbol, Integer].freeze

      # The types of value accepted in a fingerprint, which Sentry turns into Strings.
      FINGERPRINT_PART_TYPES = [String, Symbol, Numeric].freeze

      # Create Appender
      #
      # Parameters
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: :error
      #
      #   formatter: [Object|Proc|Symbol|Hash]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: Use the built-in formatter (See: #call)
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      #
      #   host: [String]
      #     Name of this host to appear in log messages.
      #     Default: SemanticLogger.host
      #
      #   application: [String]
      #     Name of this application to appear in log messages.
      #     Default: SemanticLogger.application
      def initialize(level: :error, **args, &block)
        # Replace the Sentry Ruby logger so that we can identify its log
        # messages and not forward them to Sentry
        unless ::Sentry.initialized?
          ::Sentry.init do |config|
            logger = SemanticLogger[::Sentry]
            config.respond_to?(:sdk_logger=) ? config.sdk_logger = logger : config.logger = logger
          end
        end
        super
      end

      # Send an error notification to sentry
      def log(log)
        # Ignore logs coming from Sentry itself
        return false if log.name == "Sentry"

        context = format_log(log)
        # Copies, since the payload and named tags are the log entry's own, which every other
        # appender writes after this one, and the payload can be the application's own Hash. The
        # keys taken out below must only be left out of what is sent to Sentry.
        payload               = payload_copy(context.delete(:payload))
        named_tags            = (context[:named_tags] || {}).dup
        context[:named_tags]  = named_tags
        transaction_name      = named_tags.delete(:transaction_name)
        fingerprint           = extract_fingerprint!(named_tags) || extract_fingerprint!(payload, from_payload: true)

        user = extract_user!(named_tags, payload)
        tags = extract_tags!(context)

        ::Sentry.with_scope do |scope|
          scope.set_user(user) if user
          scope.set_level(context.delete(:level)) if context[:level]
          scope.set_fingerprint(fingerprint) if fingerprint
          scope.set_transaction_name(transaction_name) if transaction_name
          scope.set_tags(tags)
          scope.set_extras(context)
          scope.set_extras(payload)

          if log.exception
            ::Sentry.capture_exception(log.exception)
          elsif log.backtrace
            ::Sentry.capture_message(context[:message], backtrace: log.backtrace)
          else
            ::Sentry.capture_message(context[:message])
          end
        end

        true
      end

      private

      # Use Raw Formatter by default
      def default_formatter
        SemanticLogger::Formatters::Raw.new
      end

      # Extract user data from named tags or payload.
      #
      # Keys :user_id and :user_email will be used as :id and :email respectively.
      # Keys :username and :ip_address will be used verbatim.
      #
      # Any additional value nested in a :user key will be added, provided any of
      # the above keys is already present.
      #
      # The payload can hold untrusted data, such as a request body, so taking the user from it is
      # deprecated, and the named tags win: a payload field is only taken when the named tags do not
      # set it, and its value is a String, Symbol, or Integer. A payload value that is not taken is
      # left where it is, and sent to Sentry as data.
      def extract_user!(named_tags, payload)
        user = {}

        USER_KEYS.each do |source_key, target_key|
          value = named_tags.delete(source_key)
          if value
            user[target_key] = value
          elsif user_value?(payload[source_key])
            user[target_key] = payload.delete(source_key)
            payload_context_deprecated
          end
        end

        return if user.empty?

        user.merge!(named_tags.delete(:user)) if named_tags[:user].is_a?(Hash)
        merge_payload_user!(user, payload)
        user
      end

      # Adds the fields of a :user Hash in the payload that the user does not have yet, when each of
      # its keys is a Symbol or String, and each of its values a String, Symbol, or Integer.
      def merge_payload_user!(user, payload)
        extras = payload[:user]
        return unless extras.is_a?(Hash) && extras.all? { |key, value| user_key?(key) && user_value?(value) }

        payload.delete(:user)
        payload_context_deprecated
        extras.each do |key, value|
          user[key.to_sym] = value unless user.key?(key.to_sym) || user.key?(key.to_s)
        end
      end

      def user_key?(key)
        key.is_a?(Symbol) || key.is_a?(String)
      end

      def user_value?(value)
        USER_VALUE_TYPES.any? { |type| value.is_a?(type) }
      end

      # Returns [Array<String>] the fingerprint taken from the named tags or payload, an Array of
      # Strings, Symbols, or numbers. Returns nil when there is none, or it is of another type, which
      # is then left where it is and sent to Sentry as data. As for the user, taking it from the
      # payload is deprecated.
      def extract_fingerprint!(source, from_payload: false)
        fingerprint = source[:fingerprint]
        return unless fingerprint.is_a?(Array) && fingerprint.all? { |part| fingerprint_part?(part) }

        payload_context_deprecated if from_payload
        source.delete(:fingerprint).map(&:to_s)
      end

      def fingerprint_part?(part)
        FINGERPRINT_PART_TYPES.any? { |type| part.is_a?(type) }
      end

      # Returns [Hash] a copy of the payload that keys can be taken out of. A payload that is not a
      # Hash is sent to Sentry as the extra named payload.
      def payload_copy(payload)
        case payload
        when nil  then {}
        when Hash then payload.dup
        else {payload: payload}
        end
      end

      # Warns once that the Sentry user or fingerprint was taken from the payload.
      def payload_context_deprecated
        return if @payload_context_deprecated

        @payload_context_deprecated = true
        Kernel.warn(
          "SemanticLogger::Appender::SentryRuby took the Sentry user or fingerprint from the log payload. " \
          "This is deprecated and will be removed in v6, since the payload can hold untrusted data: " \
          "set them with named tags instead, for example SemanticLogger.tagged(user_id: user.id).",
          category: :deprecated
        )
      end

      # Extract tags.
      #
      # Named tags will be stringified (both key and value).
      # Unnamed tags will be stringified and joined with a comma. Then they will
      # be used as a "tag" named tag. If such a tag already exists, it is also
      # joined with a comma.
      #
      # Finally, the tag names are limited to 32 characters and the tag values to 256.
      #
      def extract_tags!(context)
        named_tags = context.delete(:named_tags) || {}
        named_tags = named_tags.to_h { |k, v| [k.to_s, v.to_s] }
        tags = context.delete(:tags)
        named_tags.merge!("tag" => tags.join(", ")) { |_, v1, v2| "#{v1}, #{v2}" } if tags
        named_tags.to_h { |k, v| [k[0...32], v[0...256]] }
      end
    end
  end
end
