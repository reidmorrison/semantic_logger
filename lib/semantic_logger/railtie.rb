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
    initializer :initialize_semantic_logger, :before => :initialize_logger do
      config = Rails.application.config

      logger = Rails.logger || config.logger || begin
        path = config.paths.log.to_a.first
        logger = ActiveSupport::BufferedLogger.new(path)
        # Translate trace to debug level for BufferedLogger
        level = config.log_level == :trace ? :debug : config.log_level
        logger.level = ActiveSupport::BufferedLogger.const_get(level.to_s.upcase)
        logger.auto_flushing = false if Rails.env.production?
        logger
      rescue StandardError => e
        logger = ActiveSupport::BufferedLogger.new(STDERR)
        logger.level = ActiveSupport::BufferedLogger::WARN
        logger.warn(
          "Rails Error: Unable to access log file. Please ensure that #{path} exists and is chmod 0666. " +
            "The log level has been raised to WARN and the output directed to STDERR until the problem is fixed."
        )
        logger
      end

      # First set the internal logger to the default file one used by Rails in case something goes wrong
      # with an appender
      SemanticLogger::Logger.logger = logger

      # Add the Rails Logger to the list of appenders
      SemanticLogger::Logger.appenders << SemanticLogger::Appender::Logger.new(logger)

      # Set the default log level based on the Rails config
      SemanticLogger::Logger.default_level = config.log_level

      # Replace the default Rails loggers
      Rails.logger = config.logger = SemanticLogger::Logger.new(Rails)
      if defined?(ActiveRecord::Base)
        ActiveRecord::Base.logger = SemanticLogger::Logger.new(ActiveRecord)
      end
      if defined?(ActionController::Base)
        ActionController::Base.logger = SemanticLogger::Logger.new(ActionController)
      end
      if defined?(ActiveResource::Base)
        ActiveResource::Base.logger = SemanticLogger::Logger.new(ActiveResource)
      end

      SemanticLogger::Logger.logger.info "SemanticLogger initialized"
    end

  end
end
