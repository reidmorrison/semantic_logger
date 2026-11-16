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

      # The key of the Sentry scope of the thread that logged the entry, as captured with the entry.
      SCOPE_CAPTURE_KEY = :sentry_scope

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
        # Sentry keeps the user, tags, contexts, breadcrumbs, and trace of a request in the Sentry
        # scope of the thread or fiber handling it, but #log runs on the appender thread.
        SemanticLogger::Logger.subscribe(method(:capture_scope))
      end

      # Stops capturing the Sentry scope of each log entry.
      def close
        SemanticLogger::Logger.unsubscribe(method(:capture_scope))
      end

      # Send an error notification to sentry
      def log(log)
        # Ignore logs coming from Sentry itself
        return false if log.name == "Sentry"

        # Sentry serializes the event with JSON.generate itself, which raises for a binary String
        # that holds bytes outside ASCII (json 3.1), or warns about it (json 2.8 to 3.0.x), and for
        # invalid UTF-8, and then loses the event. So the data is sent as a copy with its text
        # converted to valid UTF-8, as the JSON formatters write it, and a Hash or Array nested too
        # deeply, or that holds itself, cut off there as they cut it off (see Utils.encode_utf8).
        # Any other object is sent as it is, for Sentry to write as it writes it.
        context = format_log(log) { |data| Utils.encode_utf8(data) }
        # The payload and named tags are this appender's own copies (above), so the keys taken out
        # below are left out only of what is sent to Sentry.
        payload               = payload_extras(context.delete(:payload), log.payload)
        named_tags            = (context[:named_tags] = like_original(context[:named_tags] || {}, log.named_tags))
        transaction_name      = named_tags.delete(:transaction_name)
        fingerprint           = extract_fingerprint!(named_tags) || extract_fingerprint!(payload, from_payload: true)

        user = extract_user!(named_tags, payload)
        tags = extract_tags!(context)

        ::Sentry.with_scope do |scope|
          apply_captured_scope(scope, log)
          scope.set_user(merged_user(scope.user, user)) if user
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

      # As an on_log subscriber, on the thread that logs the entry, keeps a copy of its Sentry scope
      # with the entry when it meets this appender's level. The filter is left to #log, so that it
      # runs once, on the appender thread.
      #
      # The copy leaves out the Rack env: Sentry reads and rewinds the request body in it as it builds
      # the request of an event, which must not happen on the appender thread while the request is
      # still using it, or after it has closed the body.
      def capture_scope(log)
        return if log.captured(SCOPE_CAPTURE_KEY) || log.name == "Sentry"
        return unless ::Sentry.initialized? && meets_log_level?(log)

        scope = ::Sentry.get_current_scope&.dup
        return unless scope

        scope.set_rack_env(nil)
        log.capture(SCOPE_CAPTURE_KEY, scope)
      end

      # Starts the scope of the event from the Sentry scope captured when the entry was logged, so
      # that the event has the user, tags, contexts, breadcrumbs, trace, and event processors of the
      # thread that logged it. Copies it again, since the scope adds tags and extras to its Hashes,
      # which would otherwise be the ones held by the log entry.
      def apply_captured_scope(scope, log)
        captured = log.captured(SCOPE_CAPTURE_KEY)
        return unless captured.is_a?(::Sentry::Scope)

        captured = captured.dup
        scope.update_from_scope(captured)
        captured.event_processors.each { |processor| scope.add_event_processor(&processor) }
      end

      # Returns [Hash] the Sentry user of the thread with the fields of the user taken from the
      # named tags, whose keys are Symbols, in place of the same fields, whether keyed by a String or
      # a Symbol.
      def merged_user(thread_user, user)
        thread_user.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }.merge(user)
      end

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

      # Returns [Hash] the payload, from this appender's own copy, as a Hash that keys can be taken out
      # of. A payload that is not a Hash is sent to Sentry as the extra named payload.
      def payload_extras(payload, original)
        case payload
        when nil  then {}
        when Hash then like_original(payload, original)
        else {payload: payload}
        end
      end

      # Returns [Hash] this appender's copy of the payload or named tags as a Hash of the class of the
      # log entry's own, such as HashWithIndifferentAccess, so that the keys taken out of it, such as
      # :user_id, are found as in the application's Hash. The class's own #update may convert the
      # nested Hashes too, as HashWithIndifferentAccess does. A plain Hash, or one whose class cannot
      # be rebuilt this way, is returned as it is.
      def like_original(copy, original)
        return copy if original.instance_of?(Hash) || !original.is_a?(Hash)

        rebuilt = original.class.new.update(copy)
        rebuilt.is_a?(Hash) ? rebuilt : copy
      rescue StandardError
        copy
      end

      # Warns once that the Sentry user or fingerprint was taken from the payload.
      def payload_context_deprecated
        return if @payload_context_deprecated

        @payload_context_deprecated = true
        Deprecation.warn(
          "SemanticLogger::Appender::SentryRuby took the Sentry user or fingerprint from the log payload. " \
          "This is deprecated and will be removed in v6, since the payload can hold untrusted data: " \
          "set them with named tags instead, for example SemanticLogger.tagged(user_id: user.id)."
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
