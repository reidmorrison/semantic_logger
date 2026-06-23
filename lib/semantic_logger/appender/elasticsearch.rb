begin
  require "elasticsearch"
rescue LoadError
  raise LoadError,
        'Gem elasticsearch is required for logging to Elasticsearch. Please add the gem "elasticsearch" to your Gemfile.'
end

require "semantic_logger/appender/elasticsearch_base"

# Forward all log messages to Elasticsearch.
#
# Example:
#
#   SemanticLogger.add_appender(
#     appender: :elasticsearch,
#     url:      'http://localhost:9200'
#   )
module SemanticLogger
  module Appender
    class Elasticsearch < ElasticsearchBase
      # Backwards compatible accessor for the client arguments.
      alias elasticsearch_args client_args

      private

      def client_class
        ::Elasticsearch::Client
      end

      def version_supports_type?
        Gem::Version.new(::Elasticsearch::VERSION) < Gem::Version.new(7)
      end
    end
  end
end
