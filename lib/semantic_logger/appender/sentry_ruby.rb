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
        ::Sentry.init { |config| config.logger = SemanticLogger[::Sentry] } unless ::Sentry.initialized?
        super(level: level, **args, &block)
      end

      # Send an error notification to sentry
      def log(log)
        # Ignore logs coming from Sentry itself
        return false if log.name == "Sentry"

        context = formatter.call(log, self)
        payload = context.delete(:payload) || {}
        named_tags = context[:named_tags] || {}
        transaction_name = named_tags.delete(:transaction_name)

        user = extract_user!(named_tags, payload)
        tags = extract_tags!(context)

        fingerprint = payload.delete(:fingerprint)

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
      def extract_user!(*sources)
        keys = {user_id: :id, username: :username, user_email: :email, ip_address: :ip_address}

        user = {}

        sources.each do |source|
          keys.each do |source_key, target_key|
            value = source.delete(source_key)
            user[target_key] = value if value
          end
        end

        return if user.empty?

        sources.each do |source|
          extras = source.delete(:user)
          user.merge!(extras) if extras.is_a?(Hash)
        end

        user
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
        named_tags = named_tags.map { |k, v| [k.to_s, v.to_s] }.to_h
        tags = context.delete(:tags)
        named_tags.merge!("tag" => tags.join(", ")) { |_, v1, v2| "#{v1}, #{v2}" } if tags
        named_tags.map { |k, v| [k[0...32], v[0...256]] }.to_h
      end
    end
  end
end
