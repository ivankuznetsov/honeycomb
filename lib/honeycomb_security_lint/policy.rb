# frozen_string_literal: true

require_relative "../honeycomb_registry"

module HoneycombSecurityLint
  class Policy
    SCHEMA = "honeycomb.security-lint-policy/v1"
    ROOT_KEYS = %w[schema baseline_network_hosts fixture_suppressions limits].freeze
    LIMIT_KEYS = %w[
      max_file_bytes max_total_bytes max_files max_artifact_bytes max_rendered_items
    ].freeze
    SECURITY_KEYS = %w[network_host_reasons suppressions].freeze
    SUPPRESSION_KEYS = %w[fingerprint reason].freeze
    HOST_PATTERN = /\A(?=.{1,259}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}(?::\d{1,5})?\z/

    attr_reader :baseline_network_hosts, :fixture_suppressions, :limits

    def self.load(path)
      new(HoneycombRegistry::SafeYAML.load_file(path))
    rescue HoneycombRegistry::SafeYAML::Invalid => e
      raise Contracts::Invalid, "invalid policy: #{e.code}: #{e.message}"
    end

    def initialize(document)
      errors = []
      unless document.is_a?(Hash)
        raise Contracts::Invalid, "policy must be an object"
      end
      unknown = document.keys - ROOT_KEYS
      errors.concat(unknown.sort.map { |key| "policy.#{key} is unknown" })
      errors << "policy schema must be #{SCHEMA.inspect}" unless document["schema"] == SCHEMA
      @baseline_network_hosts = validate_hosts(document["baseline_network_hosts"], "baseline_network_hosts", errors)
      @fixture_suppressions = validate_fingerprints(document["fixture_suppressions"], "fixture_suppressions", errors)
      @limits = document["limits"]
      unless @limits.is_a?(Hash)
        errors << "policy.limits must be an object"
        @limits = {}
      else
        (LIMIT_KEYS - @limits.keys).each { |key| errors << "policy.limits.#{key} is required" }
        (@limits.keys - LIMIT_KEYS).each { |key| errors << "policy.limits.#{key} is unknown" }
        @limits.each do |key, value|
          errors << "policy.limits.#{key} must be a positive integer" unless value.is_a?(Integer) && value.positive?
        end
      end
      raise Contracts::Invalid, errors unless errors.empty?
    end

    def security_extension(manifest)
      extension = manifest["x-security"]
      return {"network_host_reasons" => {}, "suppressions" => []} if extension.nil?

      errors = []
      unless extension.is_a?(Hash)
        raise Contracts::Invalid, "manifest.x-security must be an object"
      end
      (SECURITY_KEYS - extension.keys).each { |key| errors << "manifest.x-security.#{key} is required" }
      (extension.keys - SECURITY_KEYS).each { |key| errors << "manifest.x-security.#{key} is unknown" }
      reasons = extension["network_host_reasons"]
      unless reasons.is_a?(Hash)
        errors << "manifest.x-security.network_host_reasons must be an object"
        reasons = {}
      end
      permission_hosts = Array(manifest.dig("permissions", "network_hosts"))
      reasons.each do |host, reason|
        normalized = normalize_host(host)
        errors << "manifest.x-security host #{host.inspect} is invalid" unless normalized == host && valid_host?(host)
        errors << "manifest.x-security cannot grant undeclared host #{host.inspect}" unless permission_hosts.include?(host)
        errors << "manifest.x-security host #{host.inspect} requires a reason" unless reason.is_a?(String) && !reason.strip.empty?
      end
      suppressions = extension["suppressions"]
      unless suppressions.is_a?(Array)
        errors << "manifest.x-security.suppressions must be an array"
        suppressions = []
      end
      seen = {}
      suppressions.each_with_index do |request, index|
        path = "manifest.x-security.suppressions[#{index}]"
        unless request.is_a?(Hash)
          errors << "#{path} must be an object"
          next
        end
        (SUPPRESSION_KEYS - request.keys).each { |key| errors << "#{path}.#{key} is required" }
        (request.keys - SUPPRESSION_KEYS).each { |key| errors << "#{path}.#{key} is unknown" }
        fingerprint = request["fingerprint"]
        unless fingerprint.is_a?(String) && Contracts::SHA256_PATTERN.match?(fingerprint)
          errors << "#{path}.fingerprint must be one exact SHA-256 fingerprint"
        end
        errors << "#{path}.reason is required" unless request["reason"].is_a?(String) && !request["reason"].strip.empty?
        errors << "#{path}.fingerprint is duplicated" if seen[fingerprint]
        seen[fingerprint] = true
      end
      raise Contracts::Invalid, errors unless errors.empty?

      {"network_host_reasons" => reasons.sort.to_h, "suppressions" => suppressions.sort_by { |entry| entry["fingerprint"] }}
    end

    def normalize_host(value)
      value.to_s.downcase.sub(/\.$/, "")
    end

    private

    def validate_hosts(value, path, errors)
      unless value.is_a?(Array)
        errors << "policy.#{path} must be an array"
        return []
      end
      normalized = value.map { |host| normalize_host(host) }
      errors << "policy.#{path} must contain normalized concrete DNS hosts" unless value == normalized && value.all? { |host| valid_host?(host) }
      errors << "policy.#{path} must be sorted and unique" unless value == value.uniq.sort
      normalized
    end

    def valid_host?(host)
      return false unless HOST_PATTERN.match?(host)

      port = host[/:(\d+)\z/, 1]
      port.nil? || port.to_i.between?(1, 65_535)
    end

    def validate_fingerprints(value, path, errors)
      unless value.is_a?(Array)
        errors << "policy.#{path} must be an array"
        return []
      end
      errors << "policy.#{path} must contain exact SHA-256 fingerprints" unless value.all? { |fingerprint| fingerprint.is_a?(String) && Contracts::SHA256_PATTERN.match?(fingerprint) }
      errors << "policy.#{path} must be sorted and unique" unless value == value.uniq.sort
      value
    end
  end
end
