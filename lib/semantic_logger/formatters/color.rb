# Load Amazing Print, or Awesome Print if available
begin
  require "amazing_print"
rescue LoadError
  begin
    require "awesome_print"
  rescue LoadError
    nil
  end
end

module SemanticLogger
  module Formatters
    class Color < Default
      attr_accessor :color_map, :color

      # Supply a custom color map for every log level
      class ColorMap
        attr_accessor :trace, :debug, :info, :warn, :error, :fatal, :bold, :clear

        def initialize(trace: AnsiColors::MAGENTA,
                       debug: AnsiColors::GREEN,
                       info: AnsiColors::CYAN,
                       warn: AnsiColors::BOLD,
                       error: AnsiColors::RED,
                       fatal: AnsiColors::RED,
                       bold: AnsiColors::BOLD,
                       clear: AnsiColors::CLEAR)
          @trace = trace
          @debug = debug
          @info  = info
          @warn  = warn
          @error = error
          @fatal = fatal
          @bold  = bold
          @clear = clear
        end

        def [](level)
          public_send(level)
        end
      end

      # Adds color to the default log formatter
      #
      # Example:
      #   # Use a colorized output logger.
      #   SemanticLogger.add_appender(io: $stdout, formatter: :color)
      #
      # Example:
      #   # Use a colorized output logger changing the color for info to yellow.
      #   SemanticLogger.add_appender(io: $stdout, formatter: {color: {color_map: {info: SemanticLogger::AnsiColors::YELLOW}}})
      #
      # Example:
      #   # Override the Awesome Print options to output hashes over multiple lines:
      #   SemanticLogger.add_appender(io: $stdout, formatter: {color: {ap: {multiline: true}}})
      #
      #   # Calling the appender added above:
      #   SemanticLogger['Test'].info('hi', {a: 1, b: 2})
      #   => true
      #   => 2019-02-12 11:47:50.794339 I [35832:70112015269920] Test -- hi -- {
      #        :a => 1,
      #        :b => 2
      #      }
      #
      # Parameters:
      #  ap: [Hash]
      #    Any valid Amazing Print option for rendering data.
      #    These options can also be changed be creating a `~/.aprc` file.
      #    See: https://github.com/amazing-print/amazing_print
      #
      #    Note: The option :multiline is set to false if not supplied.
      #    Note: Has no effect if Awesome Print is not installed.
      #
      #  color_map: [Hash | SemanticLogger::Formatters::Color::ColorMap]
      #    ColorMaps each of the log levels to a color
      def initialize(ap: {multiline: false}, color_map: ColorMap.new, **args)
        @ai_options = ap
        @color_map  = color_map.is_a?(ColorMap) ? color_map : ColorMap.new(color_map)
        super(**args)
      end

      def level
        "#{color}#{super}#{color_map.clear}"
      end

      def tags
        return if log.tags.nil? || log.tags.empty?

        tags = log.tags.map { |tag| cleanse(tag) }
        "[#{color}#{tags.join("#{color_map.clear}] [#{color}")}#{color_map.clear}]"
      end

      # Named Tags
      def named_tags
        named_tags = log.named_tags
        return if named_tags.nil? || named_tags.empty?

        list = []
        named_tags.each_pair { |name, value| list << "#{color}#{cleanse(name)}: #{cleanse(value)}#{color_map.clear}" }
        "{#{list.join(', ')}}"
      end

      def duration
        "(#{color_map.bold}#{log.duration_human}#{color_map.clear})" if log.duration
      end

      def name
        "#{color}#{super}#{color_map.clear}"
      end

      def payload
        return unless log.payload?

        if log.payload.respond_to?(:ai)
          begin
            "-- #{log.payload.ai(@ai_options)}"
          rescue StandardError
            super
          end
        else
          super
        end
      end

      def exception
        return unless log.exception

        "-- Exception: #{color}#{log.exception.class}: #{cleanse(log.exception.message)}#{color_map.clear}\n#{log.backtrace_to_s}"
      end

      def call(log, logger)
        self.color = color_map[log.level]
        super
      end
    end
  end
end
