# frozen_string_literal: true

require "json"
require "time"
require "uri"

module HoneycombRegistry
  module ListingEvidence
    SCHEMA = "honeycomb-listing-evidence/v1"
    ROOT_KEYS = %w[schema records].freeze
    RECORD_KEYS = %w[name version tier lint approval].freeze
    LINT_KEYS = %w[status release_sha256 head_sha checked_at].freeze
    APPROVAL_KEYS = %w[status release_sha256 head_sha reviewer reviewed_at review_url].freeze
    LINT_STATUSES = %w[pass pending fail].freeze
    APPROVAL_STATUSES = %w[approved pending denied].freeze
    TIER_PATTERN = /\A[a-z0-9][a-z0-9-]{0,62}\z/
    HEAD_PATTERN = Schema::REVISION_PATTERN

    Result = Struct.new(:records, :findings, :path, keyword_init: true)

    class DuplicateKey < JSON::ParserError; end

    class StrictHash < Hash
      def []=(key, value)
        raise DuplicateKey, "duplicate JSON key #{key.inspect}" if key?(key)

        super
      end
    end

    module_function

    def load(path)
      findings = Findings.new
      bytes = File.binread(path)
      source = bytes.dup.force_encoding(Encoding::UTF_8)
      unless source.valid_encoding?
        findings.add(path, "evidence.invalid_encoding", "evidence JSON must be valid UTF-8")
        return Result.new(records: [], findings: findings, path: path)
      end
      data = JSON.parse(source, object_class: StrictHash, array_class: Array,
                                create_additions: false, allow_duplicate_key: false)
      validate_root(data, path, findings)
      records = data.is_a?(Hash) && data["records"].is_a?(Array) ? data["records"] : []
      Result.new(records: records, findings: findings, path: path)
    rescue DuplicateKey => e
      findings.add(path, "evidence.duplicate_key", e.message)
      Result.new(records: [], findings: findings, path: path)
    rescue JSON::ParserError => e
      code = e.message.start_with?("duplicate key") ? "evidence.duplicate_key" : "evidence.invalid_json"
      findings.add(path, code, e.message)
      Result.new(records: [], findings: findings, path: path)
    rescue Errno::ENOENT, Errno::EACCES => e
      findings.add(path, "evidence.unreadable", e.message)
      Result.new(records: [], findings: findings, path: path)
    end

    def eligible?(record)
      record.is_a?(Hash) && record.dig("lint", "status") == "pass" &&
        record.dig("approval", "status") == "approved"
    end

    def validate_bindings(result, manifests)
      findings = Findings.new
      result.records.each_with_index do |record, index|
        next unless record.is_a?(Hash)

        record_path = "#{result.path}.records[#{index}]"
        key = [record["name"], record["version"]]
        manifest = manifests[key]
        unless manifest
          findings.add(record_path, "evidence.unknown_package",
                       "evidence name/version does not match a discovered package")
          next
        end
        %w[lint approval].each do |verdict_name|
          verdict = record[verdict_name]
          next unless verdict.is_a?(Hash) && verdict["release_sha256"]

          unless verdict["release_sha256"] == manifest["release_sha256"]
            findings.add("#{record_path}.#{verdict_name}.release_sha256",
                         "evidence.stale_release",
                         "evidence release fingerprint does not match current manifest")
          end
        end
        lint = record["lint"]
        approval = record["approval"]
        next unless lint.is_a?(Hash) && approval.is_a?(Hash)

        if lint["release_sha256"] && approval["release_sha256"] &&
           lint["release_sha256"] != approval["release_sha256"]
          findings.add(record_path, "evidence.release_mismatch",
                       "lint and approval bind different release fingerprints")
        end
        if lint["head_sha"] && approval["head_sha"] && lint["head_sha"] != approval["head_sha"]
          findings.add(record_path, "evidence.head_mismatch",
                       "lint and approval bind different review head SHAs")
        end
      end
      findings
    end

    def validate_root(data, path, findings)
      unless data.is_a?(Hash)
        findings.add(path, "evidence.invalid_type", "evidence root must be an object")
        return
      end
      validate_keys(data, path, ROOT_KEYS, ROOT_KEYS, findings)
      unless data["schema"] == SCHEMA
        findings.add("#{path}.schema", "evidence.invalid_schema", "schema must be #{SCHEMA.inspect}")
      end
      unless data["records"].is_a?(Array)
        findings.add("#{path}.records", "evidence.invalid_type", "records must be an array")
        return
      end
      seen = {}
      data["records"].each_with_index do |record, index|
        record_path = "#{path}.records[#{index}]"
        validate_record(record, record_path, findings)
        next unless record.is_a?(Hash)

        key = [record["name"], record["version"]]
        if seen.key?(key)
          findings.add(record_path, "evidence.duplicate_record",
                       "duplicate evidence record for #{key.compact.join("/")}")
        end
        seen[key] = true
      end
    end

    def validate_record(record, path, findings)
      return invalid_type(record, path, "record", findings) unless record.is_a?(Hash)

      validate_keys(record, path, %w[name version tier], RECORD_KEYS, findings)
      validate_name(record["name"], "#{path}.name", findings)
      validate_semver(record["version"], "#{path}.version", findings)
      unless record["tier"].is_a?(String) && TIER_PATTERN.match?(record["tier"])
        findings.add("#{path}.tier", "evidence.invalid_tier", "tier must be a lowercase slug")
      end
      validate_lint(record["lint"], "#{path}.lint", findings) if record.key?("lint")
      validate_approval(record["approval"], "#{path}.approval", findings) if record.key?("approval")
    end

    def validate_lint(verdict, path, findings)
      return invalid_type(verdict, path, "lint verdict", findings) unless verdict.is_a?(Hash)

      validate_keys(verdict, path, %w[status], LINT_KEYS, findings)
      status = verdict["status"]
      unless LINT_STATUSES.include?(status)
        findings.add("#{path}.status", "evidence.invalid_status",
                     "lint status must be #{LINT_STATUSES.join(", ")}")
      end
      require_identity = status && status != "pending"
      validate_identity(verdict, path, %w[release_sha256 head_sha checked_at],
                        require_identity, findings)
      validate_timestamp(verdict["checked_at"], "#{path}.checked_at", findings) if verdict.key?("checked_at")
    end

    def validate_approval(verdict, path, findings)
      return invalid_type(verdict, path, "approval verdict", findings) unless verdict.is_a?(Hash)

      validate_keys(verdict, path, %w[status], APPROVAL_KEYS, findings)
      status = verdict["status"]
      unless APPROVAL_STATUSES.include?(status)
        findings.add("#{path}.status", "evidence.invalid_status",
                     "approval status must be #{APPROVAL_STATUSES.join(", ")}")
      end
      identity_keys = %w[release_sha256 head_sha reviewer reviewed_at review_url]
      require_identity = status && status != "pending"
      validate_identity(verdict, path, identity_keys, require_identity, findings)
      if verdict.key?("reviewer") && (!verdict["reviewer"].is_a?(String) || verdict["reviewer"].strip.empty?)
        findings.add("#{path}.reviewer", "evidence.invalid_value", "reviewer must be a non-empty string")
      end
      validate_timestamp(verdict["reviewed_at"], "#{path}.reviewed_at", findings) if verdict.key?("reviewed_at")
      validate_url(verdict["review_url"], "#{path}.review_url", findings) if verdict.key?("review_url")
    end

    def validate_identity(verdict, path, keys, required, findings)
      present = keys.select { |key| verdict.key?(key) }
      if required || present.any?
        (keys - present).each do |key|
          findings.add("#{path}.#{key}", "evidence.missing_key", "identity field #{key.inspect} is required")
        end
      end
      if verdict.key?("release_sha256") &&
         (!verdict["release_sha256"].is_a?(String) || !Schema::SHA256_PATTERN.match?(verdict["release_sha256"]))
        findings.add("#{path}.release_sha256", "evidence.invalid_sha256",
                     "release_sha256 must be lowercase 64-character hexadecimal")
      end
      if verdict.key?("head_sha") &&
         (!verdict["head_sha"].is_a?(String) || !HEAD_PATTERN.match?(verdict["head_sha"]))
        findings.add("#{path}.head_sha", "evidence.invalid_head_sha",
                     "head_sha must be lowercase 40- or 64-character hexadecimal")
      end
    end

    def validate_keys(value, path, required, allowed, findings)
      required.each do |key|
        findings.add("#{path}.#{key}", "evidence.missing_key", "required key #{key.inspect} is missing") unless value.key?(key)
      end
      (value.keys - allowed).sort.each do |key|
        findings.add("#{path}.#{key}", "evidence.unknown_key", "unknown key #{key.inspect}")
      end
    end

    def validate_name(value, path, findings)
      return if value.is_a?(String) && Schema::NAME_PATTERN.match?(value)

      findings.add(path, "evidence.invalid_name", "name is not a valid honeycomb name")
    end

    def validate_semver(value, path, findings)
      SemVer.parse(value)
    rescue SemVer::Invalid => e
      findings.add(path, "evidence.invalid_semver", e.message)
    end

    def validate_timestamp(value, path, findings)
      unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
        findings.add(path, "evidence.invalid_timestamp", "timestamp must be RFC 3339 with a timezone")
        return
      end
      Time.iso8601(value)
    rescue ArgumentError
      findings.add(path, "evidence.invalid_timestamp", "timestamp must be valid RFC 3339")
    end

    def validate_url(value, path, findings)
      uri = URI.parse(value.to_s)
      valid = value.is_a?(String) && %w[http https].include?(uri.scheme) && uri.host &&
              uri.userinfo.nil? && uri.fragment.nil?
      findings.add(path, "evidence.invalid_url", "review_url must be an absolute safe HTTP(S) URL") unless valid
    rescue URI::InvalidURIError
      findings.add(path, "evidence.invalid_url", "review_url must be an absolute safe HTTP(S) URL")
    end

    def invalid_type(_value, path, label, findings)
      findings.add(path, "evidence.invalid_type", "#{label} must be an object")
      false
    end
  end
end
