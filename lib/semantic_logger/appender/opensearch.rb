begin
  require "opensearch-ruby"
rescue LoadError
  raise LoadError,
        'Gem opensearch-ruby is required for logging to OpenSearch. Please add the gem "opensearch-ruby" to your Gemfile.'
end

require "semantic_logger/appender/elasticsearch_base"

# Forward all log messages to OpenSearch (e.g. AWS OpenSearch).
#
# OpenSearch is a fork of Elasticsearch 7.10. The client API and bulk
# protocol are identical, so this appender reuses the same pipeline as the
# Elasticsearch appender; only the backing client gem differs. Use this
# appender (with the `opensearch-ruby` gem) instead of `:elasticsearch`
# when talking to an OpenSearch server, since modern `elasticsearch` gems
# reject non-Elasticsearch servers via a product check.
#
# Example:
#
#   SemanticLogger.add_appender(
#     appender: :opensearch,
#     url:      'http://localhost:9200'
#   )
module SemanticLogger
  module Appender
    class Opensearch < ElasticsearchBase
      private

      def client_class
        ::OpenSearch::Client
      end
    end
  end
end
