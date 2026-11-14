# Backtrace lines, and a cleaner for them, for the tests of backtrace cleaning.
module BacktraceCleanerFixtures
  # Has the interface of ActiveSupport::BacktraceCleaner: keeps the application's own frames,
  # relative to its root.
  class AppCleaner
    def clean(backtrace)
      backtrace.select { |line| line.start_with?("/app/") }.map { |line| line.delete_prefix("/app/") }
    end
  end

  APP_FRAME     = "/app/models/order.rb:12:in 'Order#ship'".freeze
  CLEANED_FRAME = "models/order.rb:12:in 'Order#ship'".freeze
  GEM_FRAME     = "/gems/rack-3.1.0/lib/rack/runtime.rb:24:in 'Rack::Runtime#call'".freeze
end
