module SemanticLogger
  # Formatting & colors used by optional color formatter
  module AnsiColors
    CLEAR   = "\e[0m".freeze
    BOLD    = "\e[1m".freeze
    BLACK   = "\e[30m".freeze
    RED     = "\e[31m".freeze
    GREEN   = "\e[32m".freeze
    YELLOW  = "\e[33m".freeze
    BLUE    = "\e[34m".freeze
    MAGENTA = "\e[35m".freeze
    CYAN    = "\e[36m".freeze
    WHITE   = "\e[37m".freeze

    # DEPRECATED - NOT USED
    LEVEL_MAP = {
      trace: MAGENTA,
      debug: GREEN,
      info:  CYAN,
      warn:  BOLD,
      error: RED,
      fatal: RED
    }.freeze
  end
end
