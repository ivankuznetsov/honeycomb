# frozen_string_literal: true

require "open3"
require "pathname"

module HoneycombSecurityLint
  class ChangeSet
    Result = Struct.new(:version_roots, :paths, keyword_init: true)

    class Invalid < StandardError; end

    def initialize(root:, executor: nil)
      @root = File.expand_path(root)
      @executor = executor || method(:execute)
    end

    def between(base_sha, head_sha)
      validate_sha!(base_sha, "base")
      validate_sha!(head_sha, "head")
      stdout, stderr, status = @executor.call(
        ["git", "diff", "--name-only", "-z", "--diff-filter=ACMRTUXBD", "#{base_sha}...#{head_sha}", "--", "packages"]
      )
      exit_status = status.respond_to?(:exitstatus) ? status.exitstatus : Integer(status)
      raise Invalid, "git diff failed" unless exit_status.zero?
      raise Invalid, "git diff wrote an unexpected diagnostic" unless stderr.to_s.empty?

      parse(stdout)
    rescue SystemCallError, IOError, ArgumentError => e
      raise Invalid, "could not determine changed honeycombs: #{e.class}"
    end

    def parse(bytes)
      source = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
      raise Invalid, "changed path list must be valid UTF-8" unless source.valid_encoding?
      raise Invalid, "changed path list must be NUL terminated" unless source.empty? || source.end_with?("\0")

      paths = source.split("\0", -1).tap(&:pop)
      raise Invalid, "changed path list contains duplicates" unless paths.uniq.length == paths.length

      roots = paths.map { |path| version_root(path) }.uniq.sort
      Result.new(version_roots: roots, paths: paths.sort)
    end

    private

    def execute(argv)
      Open3.capture3(*argv, chdir: @root)
    end

    def validate_sha!(value, label)
      return if value.is_a?(String) && Contracts::SHA_PATTERN.match?(value)

      raise Invalid, "#{label} SHA is invalid"
    end

    def version_root(path)
      invalid = path.empty? || path.start_with?("/") || path.include?("\\") ||
                path.match?(/[\x00-\x20\x7f]/) || Pathname.new(path).cleanpath.to_s != path
      segments = path.split("/")
      invalid ||= segments.length < 4 || segments.first != "packages"
      invalid ||= segments.any? { |segment| segment.empty? || segment == "." || segment == ".." }
      raise Invalid, "changed path is not a normalized package version path" if invalid

      name, version = segments[1], segments[2]
      raise Invalid, "changed honeycomb name is invalid" unless HoneycombRegistry::Schema::NAME_PATTERN.match?(name)
      HoneycombRegistry::SemVer.parse(version)
      "packages/#{name}/#{version}"
    rescue HoneycombRegistry::SemVer::Invalid
      raise Invalid, "changed honeycomb version is invalid"
    end
  end
end
