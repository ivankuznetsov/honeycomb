# frozen_string_literal: true

require "pathname"
require "set"
require "uri"

module HoneycombRegistry
  module Schema
    MANIFEST_SCHEMA = "honeycomb-manifest/v1"
    CORE_KEYS = %w[
      schema name version description author license hive_min_version source
      permissions files release_sha256
    ].freeze
    METADATA_KEYS = %w[schema name version description author license hive_min_version source].freeze
    DERIVED_KEYS = %w[permissions files release_sha256].freeze
    NAME_PATTERN = /\A[a-z0-9][a-z0-9-]{1,62}[a-z0-9]\z/
    EXTENSION_PATTERN = /\Ax-[a-z0-9][a-z0-9-]*\z/
    SHA256_PATTERN = /\A[0-9a-f]{64}\z/
    REVISION_PATTERN = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
    RISKS = %w[low moderate high].freeze
    CAPABILITIES = %w[filesystem-read filesystem-write network shell].freeze
    PERMISSION_KEYS = %w[
      risk capabilities network_hosts filesystem_read filesystem_write secrets
    ].freeze
    HIVE_EXTENSION_KEYS = %w[tools mapping_recommendations prompt_assets optional_inputs].freeze
    HIVE_TOOL_KEYS = %w[path].freeze
    HIVE_PROMPT_ASSET_KEYS = %w[path].freeze
    HIVE_INPUT_KEYS = %w[name authorized_slots].freeze
    HIVE_MAPPING_RECOMMENDATION_KEYS = %w[slot effort].freeze
    HIVE_MAPPING_RECOMMENDATION_EFFORTS = %w[low medium high].freeze
    HIVE_INPUT_NAME_PATTERN = /\A[A-Z][A-Z0-9_]*\z/
    HIVE_RESERVED_INPUT_NAMES = %w[
      BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_WITH BUNDLE_WITHOUT
      CDPATH ENV GEM_HOME GEM_PATH HOME IFS LANG LD_LIBRARY_PATH LD_PRELOAD
      NODE_OPTIONS PATH PERL5LIB PROMPT_COMMAND PS4 PYTHONHOME PYTHONPATH
      RUBYLIB RUBYOPT SHELL TMP TMPDIR
    ].freeze
    HIVE_RESERVED_INPUT_PREFIXES = %w[
      BASH_ BUNDLE_ CLAUDE_ CODEX_ DYLD_ GEM_ GIT_ HIVE_ LC_ OPENAI_ SSH_
    ].freeze
    HIVE_SLOT_PATTERN = /\Astages\.[a-z0-9][a-z0-9_-]*(?:\.reviewers\.[a-z0-9][a-z0-9_-]*|\.revise)?\z/

    module_function

    def validate_metadata(data, path: "manifest.yml", policy_path: default_policy_path)
      validate(data, path: path, policy_path: policy_path, require_derived: false)
    end

    def validate_manifest(data, path: "manifest.yml", policy_path: default_policy_path)
      validate(data, path: path, policy_path: policy_path, require_derived: true)
    end

    def validate(data, path:, policy_path:, require_derived:)
      findings = Findings.new
      return invalid_type(findings, path, "manifest", data, Hash) unless data.is_a?(Hash)

      required = require_derived ? CORE_KEYS : METADATA_KEYS
      validate_keys(data, path, required, CORE_KEYS, findings, allow_extensions: true)
      validate_exact(data["schema"], "#{path}.schema", MANIFEST_SCHEMA, findings)
      validate_name(data["name"], "#{path}.name", findings)
      validate_semver(data["version"], "#{path}.version", findings)
      validate_nonempty_string(data["description"], "#{path}.description", findings)
      validate_author(data["author"], "#{path}.author", findings)
      validate_license(data["license"], "#{path}.license", policy_path, findings)
      validate_semver(data["hive_min_version"], "#{path}.hive_min_version", findings)
      validate_source(data["source"], "#{path}.source", findings)

      if require_derived
        validate_permissions(data["permissions"], "#{path}.permissions", findings)
        validate_files(data["files"], "#{path}.files", data["name"], data["version"], findings)
        validate_sha256(data["release_sha256"], "#{path}.release_sha256", findings)
      end

      data.each do |key, value|
        validate_json_value(value, "#{path}.#{key}", findings) if key.is_a?(String) && key.start_with?("x-")
      end
      validate_hive_extension(data["x-hive"], "#{path}.x-hive", findings) if data.key?("x-hive")
      findings
    end

    def default_policy_path
      File.expand_path("../../policy/spdx-license-ids.txt", __dir__)
    end

    def validate_keys(value, path, required, allowed, findings, allow_extensions: false)
      return invalid_type(findings, path, path.split(".").last, value, Hash) unless value.is_a?(Hash)

      required.each do |key|
        findings.add("#{path}.#{key}", "schema.missing_key", "required key #{key.inspect} is missing") unless value.key?(key)
      end
      value.each_key do |key|
        unless key.is_a?(String)
          findings.add(path, "schema.invalid_key", "mapping keys must be strings")
          next
        end
        next if allowed.include?(key)
        next if allow_extensions && EXTENSION_PATTERN.match?(key)

        findings.add("#{path}.#{key}", "schema.unknown_key", "unknown key #{key.inspect}")
      end
      true
    end

    def validate_name(value, path, findings)
      return unless validate_nonempty_string(value, path, findings)
      return if NAME_PATTERN.match?(value)

      findings.add(path, "schema.invalid_name", "name must match #{NAME_PATTERN.inspect}")
    end

    def validate_semver(value, path, findings)
      return unless validate_nonempty_string(value, path, findings)

      SemVer.parse(value)
    rescue SemVer::Invalid => e
      findings.add(path, "schema.invalid_semver", e.message)
    end

    def validate_author(value, path, findings)
      return unless validate_keys(value, path, %w[name], %w[name url], findings)

      validate_nonempty_string(value["name"], "#{path}.name", findings)
      validate_url(value["url"], "#{path}.url", findings) if value.key?("url")
    end

    def validate_source(value, path, findings)
      return unless validate_keys(value, path, %w[url revision], %w[url revision], findings)

      validate_url(value["url"], "#{path}.url", findings)
      revision = value["revision"]
      if validate_nonempty_string(revision, "#{path}.revision", findings) && !REVISION_PATTERN.match?(revision)
        findings.add("#{path}.revision", "schema.invalid_revision",
                     "revision must be a lowercase 40- or 64-character hexadecimal commit ID")
      end
    end

    def validate_license(value, path, policy_path, findings)
      return unless validate_nonempty_string(value, path, findings)

      identifiers = File.readlines(policy_path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }.to_set
      return if identifiers.include?(value)

      findings.add(path, "schema.invalid_license", "license must be a checked-in SPDX identifier")
    rescue Errno::ENOENT, Errno::EACCES => e
      findings.add(path, "schema.license_policy", "cannot read SPDX policy: #{e.message}")
    end

    def validate_url(value, path, findings)
      return unless validate_nonempty_string(value, path, findings)

      uri = URI.parse(value)
      valid = %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty? &&
              uri.userinfo.nil? && uri.fragment.nil?
      findings.add(path, "schema.invalid_url", "URL must be an absolute HTTP(S) URL without credentials or a fragment") unless valid
    rescue URI::InvalidURIError
      findings.add(path, "schema.invalid_url", "URL must be an absolute HTTP(S) URL")
    end

    def validate_permissions(value, path, findings)
      return unless validate_keys(value, path, PERMISSION_KEYS, PERMISSION_KEYS, findings)

      unless RISKS.include?(value["risk"])
        findings.add("#{path}.risk", "schema.invalid_permission", "risk must be one of #{RISKS.join(", ")}")
      end
      validate_sorted_string_set(value["capabilities"], "#{path}.capabilities", findings,
                                 allowed: CAPABILITIES)
      %w[network_hosts filesystem_read filesystem_write secrets].each do |key|
        validate_sorted_string_set(value[key], "#{path}.#{key}", findings)
      end
    end

    def validate_files(value, path, name, version, findings)
      return invalid_type(findings, path, "files", value, Hash) unless value.is_a?(Hash)

      findings.add(path, "schema.empty_files", "files must contain at least one package file") if value.empty?
      value.each do |file_path, digest|
        unless file_path.is_a?(String)
          findings.add(path, "schema.invalid_file_path", "file paths must be strings")
          next
        end
        validate_file_path(file_path, path, name, version, findings)
        validate_sha256(digest, "#{path}[#{file_path.inspect}]", findings)
      end
    end

    def validate_hive_extension(value, path, findings)
      return unless validate_keys(value, path, %w[tools optional_inputs], HIVE_EXTENSION_KEYS, findings)

      validate_hive_tools(value["tools"], "#{path}.tools", findings)
      validate_hive_mapping_recommendations(
        value.fetch("mapping_recommendations", []), "#{path}.mapping_recommendations", findings
      )
      validate_hive_prompt_assets(value.fetch("prompt_assets", []), "#{path}.prompt_assets", findings)
      validate_hive_inputs(value["optional_inputs"], "#{path}.optional_inputs", findings)
    end

    def validate_hive_mapping_recommendations(value, path, findings)
      return invalid_type(findings, path, "mapping_recommendations", value, Array) unless value.is_a?(Array)

      slots = []
      value.each_with_index do |recommendation, index|
        recommendation_path = "#{path}[#{index}]"
        next unless validate_keys(
          recommendation, recommendation_path, %w[slot], HIVE_MAPPING_RECOMMENDATION_KEYS, findings
        )

        slot = recommendation["slot"]
        if slot.is_a?(String) && HIVE_SLOT_PATTERN.match?(slot)
          slots << slot
        else
          findings.add("#{recommendation_path}.slot", "schema.invalid_hive_mapping_recommendation_slot",
                       "slot must be a stable executable slot ID")
        end

        next unless recommendation.key?("effort")
        next if HIVE_MAPPING_RECOMMENDATION_EFFORTS.include?(recommendation["effort"])

        findings.add("#{recommendation_path}.effort", "schema.invalid_hive_mapping_recommendation_effort",
                     "effort must be one of #{HIVE_MAPPING_RECOMMENDATION_EFFORTS.join(', ')}")
      end

      return if slots.length == value.length && slots == slots.uniq.sort

      findings.add(path, "schema.noncanonical_hive_mapping_recommendations",
                   "mapping_recommendations must have unique slots sorted lexicographically")
    end

    def validate_hive_prompt_assets(value, path, findings)
      validate_hive_path_declarations(
        value, path, findings, label: "prompt_assets", keys: HIVE_PROMPT_ASSET_KEYS,
        invalid_code: "schema.invalid_hive_prompt_asset_path",
        noncanonical_code: "schema.noncanonical_hive_prompt_assets"
      )
    end

    def validate_hive_tools(value, path, findings)
      return invalid_type(findings, path, "tools", value, Array) unless value.is_a?(Array)

      paths = []
      value.each_with_index do |tool, index|
        tool_path = "#{path}[#{index}]"
        next unless validate_keys(tool, tool_path, HIVE_TOOL_KEYS, HIVE_TOOL_KEYS, findings)

        candidate = tool["path"]
        valid_path = valid_package_relative_path?(candidate)
        paths << candidate if valid_path
        unless valid_path
          findings.add("#{tool_path}.path", "schema.invalid_hive_tool_path",
                       "tool path must be a normalized package-relative path")
        end
      end
      if paths.length != value.length || paths != paths.uniq.sort
        findings.add(path, "schema.noncanonical_hive_tools",
                     "tools must have unique paths sorted lexicographically")
      end
    end

    def validate_hive_inputs(value, path, findings)
      return invalid_type(findings, path, "optional_inputs", value, Array) unless value.is_a?(Array)

      names = []
      value.each_with_index do |input, index|
        input_path = "#{path}[#{index}]"
        next unless validate_keys(input, input_path, HIVE_INPUT_KEYS, HIVE_INPUT_KEYS, findings)

        name = input["name"]
        if valid_hive_input_name?(name)
          names << name
        else
          findings.add("#{input_path}.name", "schema.invalid_hive_input_name",
                       "input name must be a portable uppercase environment variable name")
        end
        slots = input["authorized_slots"]
        unless slots.is_a?(Array) && !slots.empty? &&
               slots.all? { |slot| slot.is_a?(String) && HIVE_SLOT_PATTERN.match?(slot) }
          findings.add("#{input_path}.authorized_slots", "schema.invalid_hive_input_slots",
                       "authorized_slots must be a non-empty array of stable slot IDs")
          next
        end
        if slots != slots.uniq.sort
          findings.add("#{input_path}.authorized_slots", "schema.noncanonical_hive_input_slots",
                       "authorized_slots must be unique and lexicographically sorted")
        end
      end
      if names.length != value.length || names != names.uniq.sort
        findings.add(path, "schema.noncanonical_hive_inputs",
                     "optional_inputs must have unique names sorted lexicographically")
      end
    end

    def valid_hive_input_name?(value)
      return false unless value.is_a?(String) && HIVE_INPUT_NAME_PATTERN.match?(value)
      return false if HIVE_RESERVED_INPUT_NAMES.include?(value)

      HIVE_RESERVED_INPUT_PREFIXES.none? { |prefix| value.start_with?(prefix) }
    end

    def validate_hive_path_declarations(value, path, findings, label:, keys:, invalid_code:, noncanonical_code:)
      return invalid_type(findings, path, label, value, Array) unless value.is_a?(Array)

      paths = []
      value.each_with_index do |entry, index|
        entry_path = "#{path}[#{index}]"
        next unless validate_keys(entry, entry_path, keys, keys, findings)

        candidate = entry["path"]
        paths << candidate if valid_package_relative_path?(candidate)
        unless valid_package_relative_path?(candidate)
          findings.add("#{entry_path}.path", invalid_code,
                       "#{label} path must be a normalized package-relative path")
        end
      end
      if paths.length != value.length || paths != paths.uniq.sort
        findings.add(path, noncanonical_code,
                     "#{label} must have unique paths sorted lexicographically")
      end
    end

    def valid_package_relative_path?(value)
      return false unless value.is_a?(String) && !value.empty? && value == value.strip
      return false if value.include?("\\") || value.include?("\0") || Pathname.new(value).absolute?

      segments = value.split("/")
      segments.none? { |segment| segment.empty? || segment == "." || segment == ".." } &&
        Pathname.new(value).cleanpath.to_s == value
    end

    def validate_file_path(value, path, name, version, findings)
      invalid = value.empty? || value.include?("\\") || value.start_with?("/") || value.include?("\0")
      segments = value.split("/")
      invalid ||= segments.any? { |segment| segment.empty? || segment == "." || segment == ".." }
      invalid ||= Pathname.new(value).cleanpath.to_s != value
      prefix = "packages/#{name}/#{version}/" if name.is_a?(String) && version.is_a?(String)
      invalid ||= prefix && !value.start_with?(prefix)
      findings.add("#{path}[#{value.inspect}]", "schema.invalid_file_path",
                   "file path must be a normalized repository-relative path inside the version directory") if invalid
    end

    def validate_sha256(value, path, findings)
      if !value.is_a?(String) || !SHA256_PATTERN.match?(value)
        findings.add(path, "schema.invalid_sha256", "value must be a lowercase 64-character SHA-256")
      end
    end

    def validate_sorted_string_set(value, path, findings, allowed: nil)
      unless value.is_a?(Array)
        invalid_type(findings, path, path.split(".").last, value, Array)
        return
      end
      unless value.all? { |entry| entry.is_a?(String) && !entry.empty? }
        findings.add(path, "schema.invalid_permission", "values must be non-empty strings")
        return
      end
      if value != value.uniq.sort
        findings.add(path, "schema.noncanonical_set", "values must be unique and lexicographically sorted")
      end
      if value.include?("*") && value.length > 1
        findings.add(path, "schema.noncanonical_wildcard", "wildcard must be the only value")
      end
      unknown = allowed ? value - allowed : []
      unless unknown.empty?
        findings.add(path, "schema.invalid_permission", "unknown values: #{unknown.join(", ")}")
      end
    end

    def validate_nonempty_string(value, path, findings)
      return true if value.is_a?(String) && !value.strip.empty?

      findings.add(path, "schema.invalid_value", "value must be a non-empty string")
      false
    end

    def validate_exact(value, path, expected, findings)
      return if value == expected

      findings.add(path, "schema.invalid_value", "value must be #{expected.inspect}")
    end

    def validate_json_value(value, path, findings)
      case value
      when Hash
        value.each do |key, child|
          unless key.is_a?(String)
            findings.add(path, "schema.invalid_extension", "extension mapping keys must be strings")
            next
          end
          validate_json_value(child, "#{path}.#{key}", findings)
        end
      when Array
        value.each_with_index { |child, index| validate_json_value(child, "#{path}[#{index}]", findings) }
      when String, Integer, TrueClass, FalseClass, NilClass
        nil
      when Float
        findings.add(path, "schema.invalid_extension", "extension numbers must be finite") unless value.finite?
      else
        findings.add(path, "schema.invalid_extension", "extension values must be JSON-like primitives")
      end
    end

    def invalid_type(findings, path, label, value, expected)
      findings.add(path, "schema.invalid_type", "#{label} must be a #{expected}; got #{value.class}")
      false
    end
  end
end
