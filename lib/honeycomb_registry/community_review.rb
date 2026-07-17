# frozen_string_literal: true

require "date"
require "json"
require "open3"
require "pathname"

module HoneycombRegistry
  module CommunityReview
    KEYS = %w[
      reviewer name version source_sha release_sha256 head_sha reviewed_at verdict
      conflict_of_interest
    ].freeze
    HEADINGS = ["Scope reviewed", "Permission observations", "Findings", "Rationale"].freeze
    VERDICTS = %w[approve approve-with-notes warn reject].freeze
    LOGIN_PATTERN = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z/
    HEAD_PATTERN = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
    SHA256_PATTERN = /\A[0-9a-f]{64}\z/
    MAX_BYTES = 256 * 1024
    MAX_REFERENCE_BYTES = 4 * 1024 * 1024
    MAX_CHANGED_REVIEWS = 100

    class Invalid < StandardError; end

    module_function

    def validate(root:, path:, text: nil, expected_reviewer: nil, read: nil)
      root = File.expand_path(root)
      relative = normalize_path(path)
      name, version, filename = path_identity(relative)
      reviewer = File.basename(filename, ".md")
      unless LOGIN_PATTERN.match?(reviewer)
        raise Invalid, "#{relative}: review filename must be a GitHub login"
      end
      if expected_reviewer
        unless LOGIN_PATTERN.match?(expected_reviewer) && reviewer.casecmp?(expected_reviewer)
          raise Invalid, "#{relative}: review filename must match the pull-request author"
        end
      end

      reader = read || ->(candidate) { read_local(root, candidate, max_bytes: MAX_REFERENCE_BYTES) }
      bytes = text || read_local(root, relative, max_bytes: MAX_BYTES)
      validate_bytes!(relative, bytes)
      front, body = parse(bytes, relative)
      validate_record!(relative, front, body, name, version, reviewer)
      validate_bindings!(relative, front, reader)
      front
    rescue SystemCallError, IOError => e
      raise Invalid, "#{relative || path}: review input is unreadable: #{e.class}"
    end

    def validate_all(root:, expected_reviewer: nil)
      root = File.expand_path(root)
      paths = review_paths(root)
      paths.each do |path|
        relative = path.delete_prefix("#{root}/")
        validate(root: root, path: relative, expected_reviewer: expected_reviewer)
      end
      paths
    end

    def validate_catalog(root:, manifests:, records:)
      root = File.expand_path(root)
      records_by_identity = records.to_h do |record|
        [[record.fetch("name"), record.fetch("version")], record]
      end
      review_paths(root).map do |absolute|
        relative = absolute.delete_prefix("#{root}/")
        name, version, filename = path_identity(normalize_path(relative))
        reviewer = File.basename(filename, ".md")
        raise Invalid, "#{relative}: review filename must be a GitHub login" unless LOGIN_PATTERN.match?(reviewer)
        bytes = read_local(root, relative, max_bytes: MAX_BYTES)
        validate_bytes!(relative, bytes)
        front, body = parse(bytes, relative)
        validate_record!(relative, front, body, name, version, reviewer)
        manifest = manifests[[name, version]]
        record = records_by_identity[[name, version]]
        raise Invalid, "#{relative}: reviewed version has no canonical listing evidence" unless manifest && record
        validate_expected_bindings!(relative, front, manifest, record)
        [name, version]
      end.uniq.sort
    end

    def validate_changed(root:, base_sha:, head_sha:, expected_reviewer:)
      validate_revision!(base_sha, "base")
      validate_revision!(head_sha, "head")
      stdout, stderr, status = Open3.capture3(
        "git", "diff", "--name-status", "-z", "--diff-filter=ACMRTUXBD",
        "#{base_sha}...#{head_sha}", "--", "reviews", chdir: File.expand_path(root)
      )
      raise Invalid, "could not determine changed community reviews" unless status.success? && stderr.empty?

      changes = parse_changes(stdout)
      if changes.length > MAX_CHANGED_REVIEWS
        raise Invalid, "pull request changes too many community review records"
      end
      object_reader = lambda do |revision, candidate, label|
        bytes, diagnostic, result = Open3.capture3(
          "git", "show", "#{revision}:#{normalize_repository_path(candidate)}",
          chdir: File.expand_path(root)
        )
        unless result.success? && diagnostic.empty?
          raise Invalid, "#{candidate}: content is unavailable at the #{label}"
        end
        if bytes.bytesize > MAX_REFERENCE_BYTES
          raise Invalid, "#{candidate}: content exceeds the review validation limit"
        end
        bytes
      end
      reader = ->(candidate) { object_reader.call(base_sha, candidate, "trusted base") }
      changes.each do |status_code, path|
        next if status_code == "D"

        validate(
          root: root, path: path, expected_reviewer: expected_reviewer,
          text: object_reader.call(head_sha, path, "submitted head"), read: reader
        )
      end
      changes.map(&:last)
    end

    def normalize_path(path)
      value = path.to_s
      clean = Pathname.new(value).cleanpath.to_s
      unless value == clean && !value.start_with?("/") && !value.include?("\\") &&
             !value.match?(/[\x00-\x20\x7f]/)
        raise Invalid, "#{value}: review path is not normalized"
      end
      value
    end

    def review_paths(root)
      directory = File.join(root, "reviews")
      return [] unless File.directory?(directory)

      Dir.glob(File.join(directory, "**", "*"), File::FNM_DOTMATCH).sort.select do |path|
        basename = File.basename(path)
        !%w[. ..].include?(basename) && (File.file?(path) || File.symlink?(path))
      end
    end

    def parse_changes(bytes)
      source = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
      unless source.valid_encoding? && (source.empty? || source.end_with?("\0"))
        raise Invalid, "changed review list is malformed"
      end
      fields = source.split("\0", -1).tap(&:pop)
      changes = []
      until fields.empty?
        status = fields.shift
        path = fields.shift
        raise Invalid, "changed review list is incomplete" unless status && path
        if status.start_with?("R", "C")
          path = fields.shift
          raise Invalid, "changed review rename is incomplete" unless path
        end
        status_code = status[0]
        unless %w[A C D M R T U X B].include?(status_code)
          raise Invalid, "changed review status is invalid"
        end
        changes << [status_code, normalize_path(path)]
      end
      changes
    end

    def validate_revision!(value, label)
      raise Invalid, "#{label} revision is invalid" unless HEAD_PATTERN.match?(value.to_s)
    end

    def normalize_repository_path(path)
      value = Pathname.new(path.to_s).cleanpath.to_s
      if value != path || value.start_with?("/") || value.split("/").include?("..")
        raise Invalid, "repository path is not normalized"
      end
      value
    end

    def path_identity(path)
      parts = path.split("/")
      unless parts.length == 4 && parts.first == "reviews" && parts.last.end_with?(".md")
        raise Invalid, "#{path}: expected reviews/<name>/<version>/<github-user>.md"
      end
      name, version, filename = parts.values_at(1, 2, 3)
      unless Schema::NAME_PATTERN.match?(name)
        raise Invalid, "#{path}: review honeycomb name is invalid"
      end
      SemVer.parse(version)
      [name, version, filename]
    rescue SemVer::Invalid => e
      raise Invalid, "#{path}: #{e.message}"
    end

    def validate_bytes!(path, bytes)
      unless bytes.is_a?(String) && bytes.bytesize <= MAX_BYTES
        raise Invalid, "#{path}: review must be at most #{MAX_BYTES} bytes"
      end
      source = bytes.dup.force_encoding(Encoding::UTF_8)
      raise Invalid, "#{path}: review must be valid UTF-8" unless source.valid_encoding?
    end

    def read_local(root, candidate, max_bytes:)
      path = File.join(root, normalize_repository_path(candidate))
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink? && stat.size <= max_bytes
        raise Invalid, "#{candidate}: review input must be a bounded regular file"
      end
      File.binread(path)
    end

    def parse(text, path)
      match = text.match(/\A---\n(?<front>.*?)\n---\n(?<body>.*)\z/m)
      raise Invalid, "#{path}: missing strict YAML front matter" unless match

      [SafeYAML.load(match[:front], path: path), match[:body]]
    rescue SafeYAML::Invalid => e
      raise Invalid, e.message
    end

    def validate_record!(path, front, body, name, version, reviewer)
      raise Invalid, "#{path}: review front matter must be an object" unless front.is_a?(Hash)
      raise Invalid, "#{path}: review keys do not match the contract" unless front.keys.sort == KEYS.sort
      raise Invalid, "#{path}: reviewer does not match filename" unless front["reviewer"] == reviewer
      raise Invalid, "#{path}: name does not match path" unless front["name"] == name
      raise Invalid, "#{path}: version does not match path" unless front["version"] == version
      raise Invalid, "#{path}: source_sha is invalid" unless HEAD_PATTERN.match?(front.fetch("source_sha"))
      unless SHA256_PATTERN.match?(front.fetch("release_sha256"))
        raise Invalid, "#{path}: release_sha256 is invalid"
      end
      raise Invalid, "#{path}: head_sha is invalid" unless HEAD_PATTERN.match?(front.fetch("head_sha"))
      date = Date.iso8601(front.fetch("reviewed_at"))
      raise Invalid, "#{path}: reviewed_at is not canonical" unless date.iso8601 == front.fetch("reviewed_at")
      raise Invalid, "#{path}: verdict is invalid" unless VERDICTS.include?(front.fetch("verdict"))
      conflict = front.fetch("conflict_of_interest")
      unless conflict.is_a?(String) && !conflict.strip.empty?
        raise Invalid, "#{path}: conflict_of_interest is required"
      end

      headings = body.scan(/^## (.+)$/).flatten
      raise Invalid, "#{path}: review headings do not match the contract" unless headings == HEADINGS
      HEADINGS.each do |heading|
        section = body.match(/^## #{Regexp.escape(heading)}\n+(.*?)(?=^## |\z)/m)
        unless section && !section[1].strip.empty?
          raise Invalid, "#{path}: review section #{heading.inspect} is empty"
        end
      end
    rescue KeyError, Date::Error => e
      raise Invalid, "#{path}: #{e.message}"
    end

    def validate_bindings!(path, front, reader)
      package_path = "packages/#{front.fetch("name")}/#{front.fetch("version")}/manifest.yml"
      manifest = SafeYAML.load(reader.call(package_path), path: package_path)
      unless manifest.fetch("source").fetch("revision") == front.fetch("source_sha")
        raise Invalid, "#{path}: source_sha does not match the package manifest"
      end
      unless manifest.fetch("release_sha256") == front.fetch("release_sha256")
        raise Invalid, "#{path}: release_sha256 does not match the package manifest"
      end

      catalog = JSON.parse(
        reader.call("catalog.json"), object_class: ListingEvidence::StrictHash,
        array_class: Array, create_additions: false, allow_duplicate_key: false
      )
      entry = Array(catalog.fetch("entries")).find do |candidate|
        candidate["name"] == front["name"] && candidate["version"] == front["version"]
      end
      raise Invalid, "#{path}: reviewed version is not present in catalog.json" unless entry
      raise Invalid, "#{path}: source_sha does not match catalog.json" unless entry["source_sha"] == front["source_sha"]
      unless entry.dig("listing_approval", "release_sha256") == front["release_sha256"]
        raise Invalid, "#{path}: release_sha256 does not match catalog.json"
      end
      unless entry.dig("listing_approval", "head_sha") == front["head_sha"]
        raise Invalid, "#{path}: head_sha does not match the listed review head"
      end
    rescue JSON::ParserError, KeyError, SafeYAML::Invalid => e
      raise Invalid, "#{path}: canonical package/catalog binding is invalid: #{e.message}"
    end

    def validate_expected_bindings!(path, front, manifest, record)
      unless manifest.fetch("source").fetch("revision") == front.fetch("source_sha")
        raise Invalid, "#{path}: source_sha does not match the package manifest"
      end
      unless manifest.fetch("release_sha256") == front.fetch("release_sha256")
        raise Invalid, "#{path}: release_sha256 does not match the package manifest"
      end
      lint = record.fetch("lint")
      unless lint.fetch("release_sha256") == front.fetch("release_sha256")
        raise Invalid, "#{path}: release_sha256 does not match listing evidence"
      end
      unless lint.fetch("head_sha") == front.fetch("head_sha")
        raise Invalid, "#{path}: head_sha does not match the listed review head"
      end
    rescue KeyError => e
      raise Invalid, "#{path}: canonical package/catalog binding is invalid: #{e.message}"
    end
  end
end
