module SemanticLogger #:nodoc:
  class Railtie < Rails::Railtie #:nodoc:
    # Make the SemanticLogger config available in the Rails application config
    #
    # Example: Add the MongoDB logging appender in the Rails environment
    #          initializer in file config/environments/development.rb
    #
    #   Claritybase::Application.configure do
    #     # Add the MongoDB logger appender only once Rails is initialized
    #     config.after_initialize do
    #       config.semantic_logger.appenders << SemanticLogger::Appender::Mongo.new(
    #         :db => Mongo::Connection.new['development_development']
    #        )
    #     end
    #   end
    config.semantic_logger = ::SemanticLogger::Logger

    # Initialize SemanticLogger. In a Rails environment it will automatically
    # insert itself above the configured rails logger to add support for its
    # additional features
    #
    # Also, if Mongoid is installed it will automatically start logging to Mongoid
    #
    # Loaded after Rails logging is initialized since SemanticLogger will continue
    # to forward logging to the Rails Logger
    initializer :initialize_semantic_logger, :after => :initialize_logger do
      config = Rails.application.config

      # Add the Rails Logger to the list of appenders
      SemanticLogger::Logger.appenders << SemanticLogger::Appender::Logger.new(Rails.logger)

      # Set the default log level based on the Rails config
      SemanticLogger::Logger.default_level = Rails.configuration.log_level

      # Replace the default Rails loggers
      Rails.logger = config.logger = SemanticLogger::Logger.new(Rails)
      if defined?(ActiveRecord)
        ActiveRecord::Base.logger = SemanticLogger::Logger.new(ActiveRecord)
      end
    end

  end
end
