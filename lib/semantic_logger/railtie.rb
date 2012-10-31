require 'logger'
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

      # Set the default log level based on the Rails config
      SemanticLogger::Logger.default_level = config.log_level

      # Existing loggers are ignored because servers like trinidad supply their
      # own file loggers which would result in duplicate logging to the same log file
      Rails.logger = config.logger = begin
        # First check for Rails 3.2 path, then fallback to pre-3.2
        path = ((config.paths.log.to_a rescue nil) || config.paths['log']).first
        unless File.exist? File.dirname path
          FileUtils.mkdir_p File.dirname path
        end

        # Set internal logger to log to file only, in case another appender
        # experiences logging problems
        appender = SemanticLogger::Appender::File.new(path)
        appender.name = "SemanticLogger::Logger"
        SemanticLogger::Logger.logger = appender

        # Add the log file to the list of appenders
        SemanticLogger::Logger.appenders << SemanticLogger::Appender::File.new(path)
        SemanticLogger::Logger.new(Rails)
      rescue StandardError
        # If not able to log to file, log to standard error with warning level only
        SemanticLogger::Logger.default_level = :warn

        SemanticLogger::Logger.logger = SemanticLogger::Appender::File.new(STDERR)
        SemanticLogger::Logger.appenders << SemanticLogger::Appender::File.new(STDERR)

        logger = SemanticLogger::Logger.new(Rails)
        logger.warn(
          "Rails Error: Unable to access log file. Please ensure that #{path} exists and is chmod 0666. " +
            "The log level has been raised to WARN and the output directed to STDERR until the problem is fixed."
        )
        logger
      end

      # Replace the default Rails loggers
      ActiveSupport.on_load(:active_record)     { self.logger = SemanticLogger::Logger.new('ActiveRecord') }
      ActiveSupport.on_load(:action_controller) { self.logger = SemanticLogger::Logger.new('ActionController') }
      ActiveSupport.on_load(:action_mailer)     { self.logger = SemanticLogger::Logger.new('ActionMailer') }
    end

  end
end
