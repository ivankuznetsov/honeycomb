# frozen_string_literal: true

require "json"
require "digest"
require "time"
require "uri"

module HoneycombSecurityLint
  module Contracts
    EVIDENCE_SCHEMA = "honeycomb.security-lint/v1"
    APPROVAL_SCHEMA = "honeycomb.listing-approval/v1"
    STATES = %w[pass fail awaiting_maintainer expired unchanged error].freeze
    SHA_PATTERN = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
    SHA256_PATTERN = /\A[0-9a-f]{64}\z/
    NAME_PATTERN = /\A[a-z0-9][a-z0-9-]{1,62}[a-z0-9]\z/
    ROOT_KEYS = %w[
      schema event pull_request base_sha head_sha run artifact_digest state packages totals verdict
    ].freeze
    EVENT_KEYS = %w[action gate label_sha].freeze
    RUN_KEYS = %w[id attempt workflow repository].freeze
    PACKAGE_KEYS = %w[
      identity validator_findings requested_permissions scanned_files commands hosts findings
      suppressions counts verdict
    ].freeze
    IDENTITY_KEYS = %w[name version path release_sha256].freeze
    COUNT_KEYS = %w[hard advisory downgraded].freeze
    VALIDATOR_FINDING_KEYS = %w[path code message severity].freeze
    SCANNED_FILE_KEYS = %w[path bytes sha256 kind].freeze
    COMMAND_KEYS = %w[path line column kind redacted].freeze
    HOST_KEYS = %w[host path line column declared reason disposition].freeze
    FINDING_KEYS = %w[rule_id category original_severity disposition path line column fingerprint redacted_evidence message request approval].freeze
    SUPPRESSION_KEYS = %w[fingerprint reason status approval].freeze
    FINDING_REQUEST_KEYS = %w[reason].freeze
    APPROVAL_REFERENCE_KEYS = %w[reviewer reviewed_at review_url evidence_digest].freeze
    APPROVAL_ROOT_KEYS = %w[schema approvals].freeze
    APPROVAL_KEYS = %w[
      name version path release_sha256 head_sha reviewer decision reviewed_at evidence_digest
      review_url notes approved_suppressions authority
    ].freeze
    APPROVAL_REQUIRED_KEYS = (APPROVAL_KEYS - ["authority"]).freeze

    class Invalid < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = Array(errors).map(&:to_s).sort
        super(@errors.join("; "))
      end
    end

    class DuplicateKey < JSON::ParserError; end

    class StrictHash < Hash
      def []=(key, value)
        raise DuplicateKey, "duplicate JSON key #{key.inspect}" if key?(key)

        super
      end
    end

    module_function

    def parse_evidence(bytes)
      validate_evidence(parse_json(bytes))
    end

    def parse_approvals(bytes)
      validate_approvals(parse_json(bytes))
    end

    def artifact_digest_valid?(data)
      digest = data["artifact_digest"]
      digest.is_a?(String) && SHA256_PATTERN.match?(digest) &&
        digest == Digest::SHA256.hexdigest(digestable_evidence(data))
    end

    def parse_json(bytes)
      source = bytes.to_s.dup.force_encoding(Encoding::UTF_8)
      raise Invalid, "JSON must be valid UTF-8" unless source.valid_encoding?

      JSON.parse(source, object_class: StrictHash, array_class: Array,
                         create_additions: false, allow_duplicate_key: false)
    rescue DuplicateKey, JSON::ParserError => e
      raise Invalid, "invalid JSON: #{e.message.lines.first.to_s.strip}"
    end

    def canonical_json(value)
      "#{render_json(deep_sort(value), 0)}\n"
    end

    def digestable_evidence(value)
      copy = plain_copy(value)
      copy["artifact_digest"] = nil
      canonical_json(copy)
    end

    def validate_evidence(data)
      errors = []
      object(data, "$", ROOT_KEYS, ROOT_KEYS, errors)
      return invalid!(errors) unless data.is_a?(Hash)

      errors << "$.schema must be #{EVIDENCE_SCHEMA.inspect}" unless data["schema"] == EVIDENCE_SCHEMA
      object(data["event"], "$.event", EVENT_KEYS, EVENT_KEYS, errors)
      if data["event"].is_a?(Hash)
        enum(data["event"]["gate"], "$.event.gate", %w[required applied expired unchanged], errors)
        nullable_sha(data["event"]["label_sha"], "$.event.label_sha", errors)
        nonempty(data["event"]["action"], "$.event.action", errors)
      end
      positive_integer(data["pull_request"], "$.pull_request", errors)
      sha(data["base_sha"], "$.base_sha", errors)
      sha(data["head_sha"], "$.head_sha", errors)
      object(data["run"], "$.run", RUN_KEYS, RUN_KEYS, errors)
      if data["run"].is_a?(Hash)
        positive_integer(data["run"]["id"], "$.run.id", errors)
        positive_integer(data["run"]["attempt"], "$.run.attempt", errors)
        errors << "$.run.workflow must be \"Security lint\"" unless data["run"]["workflow"] == "Security lint"
        unless data["run"]["repository"].is_a?(String) && data["run"]["repository"].match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})
          errors << "$.run.repository must be an owner/repository name"
        end
      end
      nullable_sha256(data["artifact_digest"], "$.artifact_digest", errors)
      enum(data["state"], "$.state", STATES, errors)
      unless data["packages"].is_a?(Array)
        errors << "$.packages must be an array"
      else
        data["packages"].each_with_index { |entry, index| validate_package(entry, "$.packages[#{index}]", data, errors) }
        sorted = data["packages"].sort_by { |entry| entry.is_a?(Hash) ? [entry.dig("identity", "name").to_s, entry.dig("identity", "version").to_s] : [] }
        errors << "$.packages must be sorted by honeycomb name and version" unless data["packages"] == sorted
      end
      counts(data["totals"], "$.totals", errors)
      nonempty(data["verdict"], "$.verdict", errors)
      invalid!(errors)
      data
    end

    def validate_package(entry, path, root, errors)
      object(entry, path, PACKAGE_KEYS, PACKAGE_KEYS, errors)
      return unless entry.is_a?(Hash)

      identity = entry["identity"]
      object(identity, "#{path}.identity", IDENTITY_KEYS, IDENTITY_KEYS, errors)
      if identity.is_a?(Hash)
        errors << "#{path}.identity.name is invalid" unless identity["name"].is_a?(String) && NAME_PATTERN.match?(identity["name"])
        nonempty(identity["version"], "#{path}.identity.version", errors)
        semver(identity["version"], "#{path}.identity.version", errors)
        expected_path = "packages/#{identity["name"]}/#{identity["version"]}"
        errors << "#{path}.identity.path must be #{expected_path.inspect}" unless identity["path"] == expected_path
        nullable_sha256(identity["release_sha256"], "#{path}.identity.release_sha256", errors)
      end
      array(entry["validator_findings"], "#{path}.validator_findings", errors) do |finding, finding_path|
        object(finding, finding_path, VALIDATOR_FINDING_KEYS, VALIDATOR_FINDING_KEYS, errors)
        next unless finding.is_a?(Hash)

        %w[path code message severity].each { |key| nonempty(finding[key], "#{finding_path}.#{key}", errors, allow_empty: key == "path" || key == "message") }
        enum(finding["severity"], "#{finding_path}.severity", %w[error warning info], errors)
      end
      %w[scanned_files commands hosts findings suppressions].each do |key|
        errors << "#{path}.#{key} must be an array" unless entry[key].is_a?(Array)
      end
      validate_scanned_files(entry["scanned_files"], "#{path}.scanned_files", errors)
      validate_commands(entry["commands"], "#{path}.commands", errors)
      validate_hosts(entry["hosts"], "#{path}.hosts", errors)
      validate_findings(entry["findings"], "#{path}.findings", errors)
      validate_suppressions(entry["suppressions"], "#{path}.suppressions", errors)
      unless entry["requested_permissions"].nil? || entry["requested_permissions"].is_a?(Hash)
        errors << "#{path}.requested_permissions must be an object or null"
      end
      counts(entry["counts"], "#{path}.counts", errors)
      enum(entry["verdict"], "#{path}.verdict", %w[pass fail error], errors)
    end

    def validate_scanned_files(values, path, errors)
      array(values, path, errors) do |entry, entry_path|
        object(entry, entry_path, SCANNED_FILE_KEYS, SCANNED_FILE_KEYS, errors)
        next unless entry.is_a?(Hash)
        nonempty(entry["path"], "#{entry_path}.path", errors)
        nonnegative_integer(entry["bytes"], "#{entry_path}.bytes", errors)
        sha256(entry["sha256"], "#{entry_path}.sha256", errors)
        enum(entry["kind"], "#{entry_path}.kind", %w[text binary], errors)
      end
    end

    def validate_commands(values, path, errors)
      array(values, path, errors) do |entry, entry_path|
        object(entry, entry_path, COMMAND_KEYS, COMMAND_KEYS, errors)
        next unless entry.is_a?(Hash)
        %w[path kind redacted].each { |key| nonempty(entry[key], "#{entry_path}.#{key}", errors) }
        enum(entry["kind"], "#{entry_path}.kind", %w[fenced inline plain ruby yaml-string], errors)
        positive_integer(entry["line"], "#{entry_path}.line", errors)
        positive_integer(entry["column"], "#{entry_path}.column", errors)
      end
    end

    def validate_hosts(values, path, errors)
      array(values, path, errors) do |entry, entry_path|
        object(entry, entry_path, HOST_KEYS, HOST_KEYS, errors)
        next unless entry.is_a?(Hash)
        %w[host path disposition].each { |key| nonempty(entry[key], "#{entry_path}.#{key}", errors) }
        positive_integer(entry["line"], "#{entry_path}.line", errors)
        positive_integer(entry["column"], "#{entry_path}.column", errors)
        errors << "#{entry_path}.declared must be boolean" unless [true, false].include?(entry["declared"])
        errors << "#{entry_path}.reason must be a string or null" unless entry["reason"].nil? || entry["reason"].is_a?(String)
        enum(entry["disposition"], "#{entry_path}.disposition", %w[hard advisory], errors)
      end
    end

    def validate_findings(values, path, errors)
      array(values, path, errors) do |entry, entry_path|
        object(entry, entry_path, FINDING_KEYS, FINDING_KEYS, errors)
        next unless entry.is_a?(Hash)
        %w[rule_id category original_severity disposition path fingerprint redacted_evidence message].each do |key|
          nonempty(entry[key], "#{entry_path}.#{key}", errors, allow_empty: key == "redacted_evidence")
        end
        enum(entry["original_severity"], "#{entry_path}.original_severity", %w[hard advisory], errors)
        enum(entry["disposition"], "#{entry_path}.disposition", %w[hard advisory downgraded], errors)
        positive_integer(entry["line"], "#{entry_path}.line", errors)
        positive_integer(entry["column"], "#{entry_path}.column", errors)
        sha256(entry["fingerprint"], "#{entry_path}.fingerprint", errors)
        validate_nullable_object(entry["request"], "#{entry_path}.request", FINDING_REQUEST_KEYS, errors)
        validate_nullable_object(entry["approval"], "#{entry_path}.approval", APPROVAL_REFERENCE_KEYS, errors)
      end
    end

    def validate_suppressions(values, path, errors)
      array(values, path, errors) do |entry, entry_path|
        object(entry, entry_path, SUPPRESSION_KEYS, SUPPRESSION_KEYS, errors)
        next unless entry.is_a?(Hash)
        sha256(entry["fingerprint"], "#{entry_path}.fingerprint", errors)
        nonempty(entry["reason"], "#{entry_path}.reason", errors)
        enum(entry["status"], "#{entry_path}.status", %w[requested approved orphaned], errors)
        validate_nullable_object(entry["approval"], "#{entry_path}.approval", APPROVAL_REFERENCE_KEYS, errors)
      end
    end

    def validate_nullable_object(value, path, keys, errors)
      return if value.nil?
      object(value, path, keys, keys, errors)
      return unless value.is_a?(Hash)
      keys.each { |key| nonempty(value[key], "#{path}.#{key}", errors) }
      sha256(value["evidence_digest"], "#{path}.evidence_digest", errors) if value.key?("evidence_digest")
      timestamp(value["reviewed_at"], "#{path}.reviewed_at", errors) if value.key?("reviewed_at")
      safe_url(value["review_url"], "#{path}.review_url", errors) if value.key?("review_url")
    end

    def validate_approvals(data)
      errors = []
      object(data, "$", APPROVAL_ROOT_KEYS, APPROVAL_ROOT_KEYS, errors)
      return invalid!(errors) unless data.is_a?(Hash)

      errors << "$.schema must be #{APPROVAL_SCHEMA.inspect}" unless data["schema"] == APPROVAL_SCHEMA
      seen = {}
      array(data["approvals"], "$.approvals", errors) do |entry, path|
        object(entry, path, APPROVAL_REQUIRED_KEYS, APPROVAL_KEYS, errors)
        next unless entry.is_a?(Hash)

        errors << "#{path}.name is invalid" unless entry["name"].is_a?(String) && NAME_PATTERN.match?(entry["name"])
        nonempty(entry["version"], "#{path}.version", errors)
        semver(entry["version"], "#{path}.version", errors)
        expected_path = "packages/#{entry["name"]}/#{entry["version"]}"
        errors << "#{path}.path must be #{expected_path.inspect}" unless entry["path"] == expected_path
        sha256(entry["release_sha256"], "#{path}.release_sha256", errors)
        sha(entry["head_sha"], "#{path}.head_sha", errors)
        nonempty(entry["reviewer"], "#{path}.reviewer", errors)
        enum(entry["decision"], "#{path}.decision", %w[approved denied], errors)
        enum(entry["authority"], "#{path}.authority", %w[independent repository_owner], errors) if entry.key?("authority")
        timestamp(entry["reviewed_at"], "#{path}.reviewed_at", errors)
        sha256(entry["evidence_digest"], "#{path}.evidence_digest", errors)
        safe_url(entry["review_url"], "#{path}.review_url", errors)
        errors << "#{path}.notes must be a string" unless entry["notes"].is_a?(String)
        suppressions = entry["approved_suppressions"]
        unless suppressions.is_a?(Array) && suppressions.all? { |value| value.is_a?(String) && SHA256_PATTERN.match?(value) }
          errors << "#{path}.approved_suppressions must contain exact SHA-256 fingerprints"
        else
          errors << "#{path}.approved_suppressions contains duplicates" unless suppressions.uniq.length == suppressions.length
        end
        key = [entry["name"], entry["version"], entry["release_sha256"], entry["head_sha"], entry["reviewer"].to_s.downcase]
        errors << "#{path} duplicates an approval reviewer identity" if seen[key]
        seen[key] = true
      end
      invalid!(errors)
      data
    end

    def deep_sort(value)
      case value
      when Hash
        unless value.keys.all? { |key| key.is_a?(String) }
          raise JSON::GeneratorError, "canonical JSON object keys must be strings"
        end
        value.keys.sort.each_with_object({}) { |key, sorted| sorted[key] = deep_sort(value[key]) }
      when Array
        value.map { |entry| deep_sort(entry) }
      else
        value
      end
    end

    def render_json(value, depth)
      case value
      when Hash
        return "{}" if value.empty?

        entries = value.map do |key, child|
          "#{'  ' * (depth + 1)}#{json_string(key)}: #{render_json(child, depth + 1)}"
        end
        "{\n#{entries.join(",\n")}\n#{'  ' * depth}}"
      when Array
        return "[]" if value.empty?

        entries = value.map { |child| "#{'  ' * (depth + 1)}#{render_json(child, depth + 1)}" }
        "[\n#{entries.join(",\n")}\n#{'  ' * depth}]"
      when String
        json_string(value)
      when Integer
        value.to_s
      when TrueClass
        "true"
      when FalseClass
        "false"
      when NilClass
        "null"
      else
        raise JSON::GeneratorError, "canonical JSON contains unsupported #{value.class}"
      end
    end

    def json_string(value)
      source = value.dup.force_encoding(Encoding::UTF_8)
      raise JSON::GeneratorError, "canonical JSON string must be valid UTF-8" unless source.valid_encoding?

      escaped = source.each_codepoint.map do |codepoint|
        case codepoint
        when 0x08 then "\\b"
        when 0x09 then "\\t"
        when 0x0a then "\\n"
        when 0x0c then "\\f"
        when 0x0d then "\\r"
        when 0x22 then '\\"'
        when 0x5c then "\\\\"
        when 0x00..0x1f then format("\\u%04x", codepoint)
        else codepoint.chr(Encoding::UTF_8)
        end
      end.join
      "\"#{escaped}\""
    end

    def plain_copy(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), copy| copy[key] = plain_copy(child) }
      when Array
        value.map { |child| plain_copy(child) }
      else
        value
      end
    end

    def object(value, path, required, allowed, errors)
      unless value.is_a?(Hash)
        errors << "#{path} must be an object"
        return
      end
      (required - value.keys).sort.each { |key| errors << "#{path}.#{key} is required" }
      (value.keys - allowed).sort.each { |key| errors << "#{path}.#{key} is unknown" }
    end

    def array(value, path, errors)
      unless value.is_a?(Array)
        errors << "#{path} must be an array"
        return
      end
      value.each_with_index { |entry, index| yield entry, "#{path}[#{index}]" }
    end

    def counts(value, path, errors)
      object(value, path, COUNT_KEYS, COUNT_KEYS, errors)
      return unless value.is_a?(Hash)

      COUNT_KEYS.each { |key| nonnegative_integer(value[key], "#{path}.#{key}", errors) }
    end

    def nonempty(value, path, errors, allow_empty: false)
      valid = value.is_a?(String) && (allow_empty || !value.strip.empty?)
      errors << "#{path} must be #{allow_empty ? 'a string' : 'a non-empty string'}" unless valid
    end

    def enum(value, path, allowed, errors)
      errors << "#{path} must be one of #{allowed.join(', ')}" unless allowed.include?(value)
    end

    def positive_integer(value, path, errors)
      errors << "#{path} must be a positive integer" unless value.is_a?(Integer) && value.positive?
    end

    def nonnegative_integer(value, path, errors)
      errors << "#{path} must be a non-negative integer" unless value.is_a?(Integer) && value >= 0
    end

    def sha(value, path, errors)
      errors << "#{path} must be a lowercase 40- or 64-character hexadecimal SHA" unless value.is_a?(String) && SHA_PATTERN.match?(value)
    end

    def nullable_sha(value, path, errors)
      sha(value, path, errors) unless value.nil?
    end

    def sha256(value, path, errors)
      errors << "#{path} must be a lowercase 64-character SHA-256" unless value.is_a?(String) && SHA256_PATTERN.match?(value)
    end

    def nullable_sha256(value, path, errors)
      sha256(value, path, errors) unless value.nil?
    end

    def timestamp(value, path, errors)
      unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
        errors << "#{path} must be an RFC 3339 timestamp with timezone"
        return
      end
      Time.iso8601(value)
    rescue ArgumentError
      errors << "#{path} must be a valid RFC 3339 timestamp"
    end

    def semver(value, path, errors)
      HoneycombRegistry::SemVer.parse(value)
    rescue HoneycombRegistry::SemVer::Invalid, TypeError
      errors << "#{path} must be a valid SemVer"
    end

    def safe_url(value, path, errors)
      uri = URI.parse(value.to_s)
      valid = value.is_a?(String) && %w[http https].include?(uri.scheme) && uri.host &&
              uri.userinfo.nil?
      errors << "#{path} must be a safe absolute HTTP(S) URL" unless valid
    rescue URI::InvalidURIError
      errors << "#{path} must be a safe absolute HTTP(S) URL"
    end

    def invalid!(errors)
      raise Invalid, errors unless errors.empty?
    end
  end
end
