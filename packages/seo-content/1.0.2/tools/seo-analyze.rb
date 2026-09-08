#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

options = {keyword: nil}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: seo-analyze.rb [--keyword TEXT] ARTICLE.md"
  opts.on("--keyword TEXT", "Primary keyword to measure") { |value| options[:keyword] = value }
end
parser.parse!

abort(parser.to_s) unless ARGV.length == 1
path = File.expand_path(ARGV.fetch(0))
abort("article not found: #{ARGV.fetch(0)}") unless File.file?(path)

text = File.read(path, encoding: "UTF-8")
abort("article is not valid UTF-8") unless text.valid_encoding?

lines = text.lines
headings = lines.filter_map do |line|
  match = line.match(/\A(\#{1,6})\s+(.+?)\s*\z/)
  [match[1].length, match[2]] if match
end
words = text.scan(/[\p{L}\p{N}]+(?:['’-][\p{L}\p{N}]+)*/u)
links = text.scan(/\[[^\]]+\]\(([^)]+)\)/).flatten
keyword = options[:keyword]&.strip
keyword_words = keyword.to_s.scan(/[\p{L}\p{N}]+(?:['’-][\p{L}\p{N}]+)*/u).map(&:downcase)
keyword_occurrences = if keyword_words.empty?
  nil
else
  words.map(&:downcase).each_cons(keyword_words.length).count { |candidate| candidate == keyword_words }
end
density = if keyword_occurrences && words.any?
  ((keyword_occurrences.to_f / words.length) * 100).round(2)
end

h1_titles = headings.select { |level, _title| level == 1 }.map(&:last)
recommendations = []
recommendations << "Use exactly one H1" unless h1_titles.length == 1
if h1_titles.one? && !(30..65).cover?(h1_titles.first.length)
  recommendations << "Review H1 length (measured #{h1_titles.first.length}; target 30-65 characters)"
end
recommendations << "Add at least one H2 section" unless headings.any? { |level, _title| level == 2 }
recommendations << "Add source links for material factual claims" if links.empty?
if density && density > 3.0
  recommendations << "Review primary-keyword repetition (measured #{density}%; avoid forced repetition)"
end

report = {
  "schema" => "seo-analyzer/v1",
  "word_count" => words.length,
  "headings" => (1..6).to_h { |level| ["h#{level}", headings.count { |item| item.first == level }] },
  "h1_character_count" => h1_titles.one? ? h1_titles.first.length : nil,
  "links" => {
    "total" => links.length,
    "external" => links.count { |target| target.match?(%r{\Ahttps?://}i) }
  },
  "primary_keyword" => keyword.nil? || keyword.empty? ? nil : {
    "occurrences" => keyword_occurrences,
    "density_percent" => density
  },
  "recommendations" => recommendations
}

puts JSON.pretty_generate(report)
