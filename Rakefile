require "rake/clean"
require "rake/testtask"

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "semantic_logger/version"

desc "Build the semantic_logger gem"
task :gem do
  system "gem build semantic_logger.gemspec"
end

desc "Tag and push the release, then publish the gem to RubyGems"
task publish: :gem do
  system "git tag -a v#{SemanticLogger::VERSION} -m 'Tagging #{SemanticLogger::VERSION}'"
  system "git push --tags"
  system "gem push semantic_logger-#{SemanticLogger::VERSION}.gem"
  system "rm semantic_logger-#{SemanticLogger::VERSION}.gem"
end

desc "Regenerate docs/llms-full.txt from the docs markdown pages"
task :llms_full do
  pages  = %w[index api config appenders log metrics rails testing operations security upgrading]
  header = <<~HEADER
    # Semantic Logger - Complete Documentation

    > Semantic Logger is a high-performance, asynchronous structured logging framework for Ruby and Rails.

    This file concatenates every page of https://logger.reidmorrison.com for consumption by AI assistants.
    It is generated from the markdown sources in docs/ by `bundle exec rake llms_full`; do not edit it directly.
    A per-page index is available at https://logger.reidmorrison.com/llms.txt
  HEADER

  sections = pages.map do |page|
    raw = File.read("docs/#{page}.md")

    # The page title lives in front matter, which the shared docs theme renders
    # as the h1. This file strips front matter, so lift the title back out and
    # re-emit it as a heading; without this every section here would open with
    # no indication of which page it is.
    front_matter = raw[/\A---\n(.*?)\n---\n/m, 1].to_s
    title        = front_matter[/^(?:title|heading):[ \t]*(.+)$/, 1].to_s.strip.delete_prefix('"').delete_suffix('"')

    text = raw.
           sub(/\A---\n.*?\n---\n/m, ""). # Jekyll front matter
           gsub(/^\{:.*\}\n/, "").        # kramdown attribute lines ({:toc}, {:.no_toc}, ...)
           gsub(/^\* TOC\n/, "").
           gsub(/^\*\*Contents\*\*\n/, "").
           gsub(/^!\[.*\n/, "")           # images (relative paths, useless in plain text)

    body = title.empty? ? text.strip : "## #{title}\n\n#{text.strip}"
    "<!-- source: docs/#{page}.md -->\n\n#{body}\n"
  end

  File.write("docs/llms-full.txt", ([header] + sections).join("\n\n---\n\n"))
  puts "Wrote docs/llms-full.txt (#{File.size('docs/llms-full.txt')} bytes)"
end

Rake::TestTask.new(:test) do |t|
  t.pattern = "test/**/*_test.rb"
  t.verbose = true
  t.warning = false
end

begin
  require "rspec/core/rake_task"
  RSpec::Core::RakeTask.new(:spec)
rescue LoadError
  # RSpec is only available in the test/development environment.
end

task default: %i[test spec]
