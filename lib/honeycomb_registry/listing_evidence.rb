# frozen_string_literal: true

require "json"
require "time"
require "uri"

module HoneycombRegistry
  module ListingEvidence
    SCHEMA = "honeycomb-listing-evidence/v1"
    ROOT_KEYS = %w[schema records].freeze
    RECORD_KEYS = %w[
      name version release_tier current_tier permission_risk state lint approvals
      verification history advisories
    ].freeze
    LINT_KEYS = %w[status release_sha256 head_sha checked_at].freeze
    APPROVAL_KEYS = %w[
      status release_sha256 head_sha reviewer reviewed_at review_url evidence_digest
    ].freeze
    VERIFICATION_KEYS = %w[archive_sha256 signature attestation verified_at].freeze
    SIGNATURE_KEYS = %w[identity issuer url].freeze
    ATTESTATION_KEYS = %w[repository workflow url].freeze
    HISTORY_KEYS = %w[kind from to changed_at actor reason url].freeze
    ADVISORY_KEYS = %w[id title severity url published_at].freeze
    LINT_STATUSES = %w[pass pending fail].freeze
    APPROVAL_STATUSES = %w[approved denied].freeze
    TIERS = %w[community verified].freeze
    STATES = %w[listed soft_hidden yanked revoked].freeze
    RISKS = %w[low moderate high].freeze
    ADVISORY_SEVERITIES = %w[low moderate high critical].freeze
    HEAD_PATTERN = Schema::REVISION_PATTERN
    REPOSITORY_PATTERN = /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
    WORKFLOW_PATTERN = /\A([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\/\.github\/workflows\/[A-Za-z0-9_.-]+@refs\/(?:heads|tags)\/[A-Za-z0-9._\/-]+\z/

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
      findings.concat(validate_document(data, path: path))
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

    def validate_document(data, path: "$")
      findings = Findings.new
      validate_root(data, path, findings)
      findings
    end

    def eligible?(record)
      return false unless record.is_a?(Hash) && record.dig("lint", "status") == "pass"

      approvals = record["approvals"]
      return false unless approvals.is_a?(Array)
      return false if approvals.any? { |approval| approval["status"] == "denied" }

      approved = approvals.select { |approval| approval["status"] == "approved" }
                           .map { |approval| approval["reviewer"].to_s.downcase }.uniq
      approved.length >= (record["permission_risk"] == "high" ? 2 : 1)
    end

    def validate_bindings(result, manifests)
      findings = Findings.new
      result.records.each_with_index do |record, index|
        next unless record.is_a?(Hash)

        record_path = "#{result.path}.records[#{index}]"
        manifest = manifests[[record["name"], record["version"]]]
        unless manifest
          findings.add(record_path, "evidence.unknown_package",
                       "evidence name/version does not match a discovered honeycomb")
          next
        end
        unless record["permission_risk"] == manifest.dig("permissions", "risk")
          findings.add("#{record_path}.permission_risk", "evidence.permission_risk_mismatch",
                       "evidence permission risk does not match the generated manifest")
        end

        verdicts = [record["lint"], *Array(record["approvals"])]
        verdicts.each_with_index do |verdict, verdict_index|
          next unless verdict.is_a?(Hash) && verdict["release_sha256"]
          next if verdict["release_sha256"] == manifest["release_sha256"]

          label = verdict_index.zero? ? "lint" : "approvals[#{verdict_index - 1}]"
          findings.add("#{record_path}.#{label}.release_sha256", "evidence.stale_release",
                       "evidence release fingerprint does not match current manifest")
        end
        validate_verdict_bindings(record, record_path, findings)
        verification = record["verification"]
        if verification.is_a?(Hash) &&
           verification["archive_sha256"] != ReleaseVerification.archive_sha256(manifest)
          findings.add("#{record_path}.verification.archive_sha256",
                       "evidence.verification_digest_mismatch",
                       "verified archive identity does not match current immutable release")
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
      if data["records"].all? do |record|
           record.is_a?(Hash) && record["name"].is_a?(String) &&
             record["version"].is_a?(String) && SemVer::PATTERN.match?(record["version"])
         end
        sorted = data["records"].sort do |left, right|
          name = left.fetch("name") <=> right.fetch("name")
          name.zero? ? SemVer.parse(left.fetch("version")) <=> SemVer.parse(right.fetch("version")) : name
        end
        unless data["records"] == sorted
          findings.add("#{path}.records", "evidence.noncanonical_records",
                       "records must be sorted by honeycomb name and SemVer")
        end
      end
    end

    def validate_record(record, path, findings)
      return invalid_type(path, "record", findings) unless record.is_a?(Hash)

      validate_keys(record, path, RECORD_KEYS, RECORD_KEYS, findings)
      validate_name(record["name"], "#{path}.name", findings)
      validate_semver(record["version"], "#{path}.version", findings)
      validate_enum(record["release_tier"], "#{path}.release_tier", TIERS, findings)
      validate_enum(record["current_tier"], "#{path}.current_tier", TIERS, findings)
      validate_enum(record["permission_risk"], "#{path}.permission_risk", RISKS, findings)
      validate_enum(record["state"], "#{path}.state", STATES, findings)
      validate_lint(record["lint"], "#{path}.lint", findings)
      validate_approvals(record["approvals"], "#{path}.approvals", findings)
      validate_verification(record["verification"], "#{path}.verification", findings)
      validate_history(record, path, findings)
      validate_advisories(record["advisories"], "#{path}.advisories", findings)
      if record["state"] == "revoked" && (!record["advisories"].is_a?(Array) || record["advisories"].empty?)
        findings.add("#{path}.advisories", "evidence.missing_advisory",
                     "revoked honeycombs require a public advisory")
      end
      verified_ever = record["release_tier"] == "verified" || record["current_tier"] == "verified" ||
                      Array(record["history"]).any? do |entry|
                        entry.is_a?(Hash) && entry["kind"] == "tier" &&
                          [entry["from"], entry["to"]].include?("verified")
                      end
      if verified_ever && !record["verification"].is_a?(Hash)
        findings.add("#{path}.verification", "evidence.missing_verification",
                     "a current or historic Verified tier requires verification evidence")
      end
      validate_verdict_bindings(record, path, findings)
    end

    def validate_lint(verdict, path, findings)
      return invalid_type(path, "lint verdict", findings) unless verdict.is_a?(Hash)

      validate_keys(verdict, path, %w[status], LINT_KEYS, findings)
      status = verdict["status"]
      validate_enum(status, "#{path}.status", LINT_STATUSES, findings)
      identity_keys = %w[release_sha256 head_sha checked_at]
      validate_identity(verdict, path, identity_keys, status && status != "pending", findings)
      validate_timestamp(verdict["checked_at"], "#{path}.checked_at", findings) if verdict.key?("checked_at")
    end

    def validate_approvals(approvals, path, findings)
      unless approvals.is_a?(Array)
        findings.add(path, "evidence.invalid_type", "approvals must be an array")
        return
      end
      seen = {}
      approvals.each_with_index do |approval, index|
        approval_path = "#{path}[#{index}]"
        unless approval.is_a?(Hash)
          invalid_type(approval_path, "approval", findings)
          next
        end
        validate_keys(approval, approval_path, APPROVAL_KEYS, APPROVAL_KEYS, findings)
        validate_enum(approval["status"], "#{approval_path}.status", APPROVAL_STATUSES, findings)
        validate_identity(approval, approval_path,
                          %w[release_sha256 head_sha reviewer reviewed_at review_url evidence_digest],
                          true, findings)
        validate_nonempty(approval["reviewer"], "#{approval_path}.reviewer", findings)
        validate_timestamp(approval["reviewed_at"], "#{approval_path}.reviewed_at", findings)
        validate_url(approval["review_url"], "#{approval_path}.review_url", findings)
        validate_sha256(approval["evidence_digest"], "#{approval_path}.evidence_digest", findings)
        reviewer = approval["reviewer"].to_s.downcase
        if seen[reviewer]
          findings.add(approval_path, "evidence.duplicate_reviewer",
                       "a reviewer may have only one current decision")
        end
        seen[reviewer] = true
      end
      sorted = approvals.sort_by { |approval| approval.is_a?(Hash) ? approval["reviewer"].to_s.downcase : "" }
      unless approvals == sorted
        findings.add(path, "evidence.noncanonical_approvals", "approvals must be sorted by reviewer")
      end
    end

    def validate_verification(verification, path, findings)
      return if verification.nil?
      return invalid_type(path, "verification", findings) unless verification.is_a?(Hash)

      validate_keys(verification, path, VERIFICATION_KEYS, VERIFICATION_KEYS, findings)
      validate_sha256(verification["archive_sha256"], "#{path}.archive_sha256", findings)
      validate_timestamp(verification["verified_at"], "#{path}.verified_at", findings)
      signature = verification["signature"]
      attestation = verification["attestation"]
      validate_nested(signature, "#{path}.signature", SIGNATURE_KEYS, findings)
      validate_nested(attestation, "#{path}.attestation", ATTESTATION_KEYS, findings)
      return unless signature.is_a?(Hash) && attestation.is_a?(Hash)

      %w[identity issuer url].each { |key| validate_url(signature[key], "#{path}.signature.#{key}", findings, https_only: true) }
      validate_url(attestation["url"], "#{path}.attestation.url", findings, https_only: true)
      repository = attestation["repository"]
      workflow = attestation["workflow"]
      unless repository.is_a?(String) && REPOSITORY_PATTERN.match?(repository)
        findings.add("#{path}.attestation.repository", "evidence.invalid_attestation",
                     "attestation repository must be an owner/repository identity")
      end
      workflow_match = workflow.is_a?(String) && WORKFLOW_PATTERN.match(workflow)
      unless workflow_match && workflow_match[1] == repository && !workflow.include?("..")
        findings.add("#{path}.attestation.workflow", "evidence.invalid_attestation",
                     "attestation workflow must be an exact GitHub Actions workflow ref")
      end
      unless signature["identity"] == "https://github.com/#{workflow}" &&
             signature["issuer"] == "https://token.actions.githubusercontent.com"
        findings.add("#{path}.signature", "evidence.invalid_signature_identity",
                     "keyless signature identity must match the attested GitHub Actions workflow")
      end
    end

    def validate_history(record, path, findings)
      history = record["history"]
      unless history.is_a?(Array)
        findings.add("#{path}.history", "evidence.invalid_type", "history must be an array")
        return
      end
      tier = record["release_tier"]
      state = "listed"
      history.each_with_index do |entry, index|
        entry_path = "#{path}.history[#{index}]"
        unless entry.is_a?(Hash)
          invalid_type(entry_path, "history entry", findings)
          next
        end
        validate_keys(entry, entry_path, HISTORY_KEYS, HISTORY_KEYS, findings)
        validate_enum(entry["kind"], "#{entry_path}.kind", %w[tier state], findings)
        allowed = entry["kind"] == "tier" ? TIERS : STATES
        validate_enum(entry["from"], "#{entry_path}.from", allowed, findings)
        validate_enum(entry["to"], "#{entry_path}.to", allowed, findings)
        validate_timestamp(entry["changed_at"], "#{entry_path}.changed_at", findings)
        %w[actor reason].each { |key| validate_nonempty(entry[key], "#{entry_path}.#{key}", findings) }
        validate_url(entry["url"], "#{entry_path}.url", findings)
        current = entry["kind"] == "tier" ? tier : state
        unless entry["from"] == current && entry["to"] != current
          findings.add(entry_path, "evidence.invalid_history_transition",
                       "history transition must start at the preceding value and change it")
        end
        if entry["kind"] == "tier"
          tier = entry["to"]
        elsif entry["kind"] == "state"
          state = entry["to"]
        end
      end
      unless tier == record["current_tier"] && state == record["state"]
        findings.add("#{path}.history", "evidence.history_mismatch",
                     "history does not project the declared current tier and lifecycle state")
      end
      sorted = history.sort_by do |entry|
        if entry.is_a?(Hash)
          [timestamp_sort_key(entry["changed_at"]), entry["kind"].to_s, entry["actor"].to_s]
        else
          [Time.at(0), "", ""]
        end
      end
      unless history == sorted
        findings.add("#{path}.history", "evidence.noncanonical_history",
                     "history must be ordered by timestamp, kind, and actor")
      end
    end

    def validate_advisories(advisories, path, findings)
      unless advisories.is_a?(Array)
        findings.add(path, "evidence.invalid_type", "advisories must be an array")
        return
      end
      seen = {}
      advisories.each_with_index do |advisory, index|
        advisory_path = "#{path}[#{index}]"
        unless advisory.is_a?(Hash)
          invalid_type(advisory_path, "advisory", findings)
          next
        end
        validate_keys(advisory, advisory_path, ADVISORY_KEYS, ADVISORY_KEYS, findings)
        unless advisory["id"].is_a?(String) && advisory["id"].match?(/\A[A-Za-z0-9][A-Za-z0-9._-]{1,127}\z/)
          findings.add("#{advisory_path}.id", "evidence.invalid_advisory", "advisory ID is invalid")
        end
        validate_nonempty(advisory["title"], "#{advisory_path}.title", findings)
        validate_enum(advisory["severity"], "#{advisory_path}.severity", ADVISORY_SEVERITIES, findings)
        validate_url(advisory["url"], "#{advisory_path}.url", findings)
        validate_timestamp(advisory["published_at"], "#{advisory_path}.published_at", findings)
        if seen[advisory["id"]]
          findings.add(advisory_path, "evidence.duplicate_advisory", "advisory IDs must be unique")
        end
        seen[advisory["id"]] = true
      end
      sorted = advisories.sort_by do |advisory|
        advisory.is_a?(Hash) ? [timestamp_sort_key(advisory["published_at"]), advisory["id"].to_s] : [Time.at(0), ""]
      end
      unless advisories == sorted
        findings.add(path, "evidence.noncanonical_advisories",
                     "advisories must be ordered by publication time and ID")
      end
    end

    def validate_verdict_bindings(record, path, findings)
      lint = record["lint"]
      return unless lint.is_a?(Hash)

      Array(record["approvals"]).each_with_index do |approval, index|
        next unless approval.is_a?(Hash)
        if lint["release_sha256"] && approval["release_sha256"] &&
           lint["release_sha256"] != approval["release_sha256"]
          findings.add("#{path}.approvals[#{index}]", "evidence.release_mismatch",
                       "lint and approval bind different release fingerprints")
        end
        if lint["head_sha"] && approval["head_sha"] && lint["head_sha"] != approval["head_sha"]
          findings.add("#{path}.approvals[#{index}]", "evidence.head_mismatch",
                       "lint and approval bind different review head SHAs")
        end
      end
    end

    def validate_identity(value, path, keys, required, findings)
      present = keys.select { |key| value.key?(key) }
      if required || present.any?
        (keys - present).each do |key|
          findings.add("#{path}.#{key}", "evidence.missing_key", "identity field #{key.inspect} is required")
        end
      end
      validate_sha256(value["release_sha256"], "#{path}.release_sha256", findings) if value.key?("release_sha256")
      if value.key?("head_sha") &&
         (!value["head_sha"].is_a?(String) || !HEAD_PATTERN.match?(value["head_sha"]))
        findings.add("#{path}.head_sha", "evidence.invalid_head_sha",
                     "head_sha must be lowercase 40- or 64-character hexadecimal")
      end
    end

    def validate_nested(value, path, keys, findings)
      return invalid_type(path, path.split(".").last, findings) unless value.is_a?(Hash)

      validate_keys(value, path, keys, keys, findings)
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

    def validate_enum(value, path, allowed, findings)
      return if allowed.include?(value)

      findings.add(path, "evidence.invalid_value", "value must be one of #{allowed.join(", ")}")
    end

    def validate_nonempty(value, path, findings)
      return if value.is_a?(String) && !value.strip.empty?

      findings.add(path, "evidence.invalid_value", "value must be a non-empty string")
    end

    def validate_sha256(value, path, findings)
      return if value.is_a?(String) && Schema::SHA256_PATTERN.match?(value)

      findings.add(path, "evidence.invalid_sha256", "value must be lowercase 64-character hexadecimal")
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

    def timestamp_sort_key(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      Time.at(0)
    end

    def validate_url(value, path, findings, https_only: false)
      uri = URI.parse(value.to_s)
      schemes = https_only ? %w[https] : %w[http https]
      valid = value.is_a?(String) && schemes.include?(uri.scheme) && uri.host &&
              uri.userinfo.nil?
      findings.add(path, "evidence.invalid_url", "URL must be an absolute safe HTTP(S) URL") unless valid
    rescue URI::InvalidURIError
      findings.add(path, "evidence.invalid_url", "URL must be an absolute safe HTTP(S) URL")
    end

    def invalid_type(path, label, findings)
      findings.add(path, "evidence.invalid_type", "#{label} must be an object")
      false
    end
  end
end
