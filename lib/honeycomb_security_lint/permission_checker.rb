# frozen_string_literal: true

require "digest"
require "ipaddr"

module HoneycombSecurityLint
  class PermissionChecker
    WRITE_COMMAND = /\A\s*(?:sudo\s+)?(?:cp|mv|rm|mkdir|rmdir|chmod|chown|tee|touch|truncate)\b|\bsed\s+-i\b/i
    READ_COMMAND = /\A\s*(?:cat|grep|rg|find|ls|head|tail|sed|awk)\b/i
    SHELL_COMMAND = CommandExtractor::COMMAND_START
    NETWORK_COMMAND = NetworkExtractor::NETWORK_COMMAND
    ABSOLUTE_PATH = %r{(?:\A|\s)(/(?![/\\])[^\s"']+)}
    SECRET_VARIABLE = /\$(?:\{)?([A-Z][A-Z0-9_]*(?:TOKEN|KEY|SECRET|PASSWORD)[A-Z0-9_]*)(?:\})?/i

    def initialize(policy:)
      @policy = policy
    end

    def check(commands:, observations:, permissions:, security_extension:)
      permissions ||= {}
      capabilities = Array(permissions["capabilities"])
      declared_secrets = Array(permissions["secrets"])
      findings = []
      commands.each do |command|
        findings << finding("permission.shell", "Observed shell command is not declared", command, command.raw) if command.raw.match?(SHELL_COMMAND) && !capabilities.include?("shell")
        findings << finding("permission.filesystem-write", "Observed write is not declared", command, command.raw) if command.raw.match?(WRITE_COMMAND) && !capabilities.include?("filesystem-write")
        findings << finding("permission.filesystem-read", "Observed read is not declared", command, command.raw) if command.raw.match?(READ_COMMAND) && !capabilities.include?("filesystem-read")
        findings << finding("permission.network", "Observed network use is not declared", command, command.raw) if command.raw.match?(NETWORK_COMMAND) && !capabilities.include?("network")
        command.raw.scan(ABSOLUTE_PATH).flatten.each do |path|
          next if path == "/dev/null"

          findings << finding("permission.absolute-path", "Absolute filesystem path is outside declared scopes", command, path)
        end
        command.raw.scan(SECRET_VARIABLE).flatten.each do |name|
          next if declared_secrets.include?("*") || declared_secrets.include?(name)

          findings << finding("permission.secret", "Observed secret variable is not declared", command, name)
        end
      end
      hosts = observations.map do |observation|
        host_result(observation, permissions, security_extension, findings)
      end
      findings.concat(broad_permission_advisories(permissions))
      [findings.uniq { |entry| entry["fingerprint"] }.sort_by { |entry| [entry["path"], entry["line"], entry["rule_id"]] }, hosts]
    end

    private

    def host_result(observation, permissions, extension, findings)
      declared_hosts = Array(permissions["network_hosts"])
      declared = !observation.dynamic && declared_hosts.include?(observation.host)
      reason = extension.fetch("network_host_reasons", {})[observation.host]
      rule_id = if observation.dynamic
                  "network.dynamic-destination"
                elsif !declared
                  "network.undeclared-host"
                elsif ip_literal?(observation.host)
                  "network.ip-literal"
                elsif !@policy.baseline_network_hosts.include?(observation.host) && reason.to_s.strip.empty?
                  "network.missing-reason"
                end
      if rule_id
        message = {
          "network.dynamic-destination" => "Network destination is dynamic or unresolved",
          "network.undeclared-host" => "Observed network host is not declared exactly",
          "network.ip-literal" => "IP-literal network destinations are not allowed",
          "network.missing-reason" => "Package-specific network host requires a reason"
        }.fetch(rule_id)
        findings << observation_finding(rule_id, message, observation)
      end
      disposition = rule_id ? "hard" : "advisory"
      observation.evidence(declared: declared, reason: reason, disposition: disposition)
    end

    def broad_permission_advisories(permissions)
      broad = permissions.any? do |key, value|
        key != "risk" && value.is_a?(Array) && value.include?("*")
      end
      return [] unless broad || permissions["risk"] == "high"

      raw = Contracts.canonical_json(permissions)
      [{
        "rule_id" => "permission.broad-declaration", "category" => "permission",
        "original_severity" => "advisory", "disposition" => "advisory", "path" => "manifest.yml",
        "line" => 1, "column" => 1, "fingerprint" => Digest::SHA256.hexdigest("permission.broad-declaration\0#{raw}"),
        "redacted_evidence" => "Broad permissions declared", "message" => "Broad declared permissions require human review",
        "request" => nil, "approval" => nil
      }]
    end

    def observation_finding(rule_id, message, observation)
      fingerprint = Digest::SHA256.hexdigest(
        [rule_id, observation.path, observation.line, observation.column, observation.raw].join("\0")
      )
      {
        "rule_id" => rule_id, "category" => "network", "original_severity" => "hard",
        "disposition" => "hard", "path" => observation.path, "line" => observation.line,
        "column" => observation.column, "fingerprint" => fingerprint,
        "redacted_evidence" => Redactor.sanitize_text(observation.host), "message" => message,
        "request" => nil, "approval" => nil
      }
    end

    def finding(rule_id, message, command, matched)
      fingerprint = Digest::SHA256.hexdigest(
        [rule_id, command.path, command.line, command.column, matched].join("\0")
      )
      {
        "rule_id" => rule_id, "category" => "permission", "original_severity" => "hard",
        "disposition" => "hard", "path" => command.path, "line" => command.line,
        "column" => command.column, "fingerprint" => fingerprint,
        "redacted_evidence" => SecretPiiScanner.new.redact_text(matched), "message" => message,
        "request" => nil, "approval" => nil
      }
    end

    def ip_literal?(host)
      candidate = host.sub(/:\d+\z/, "")
      candidate = candidate.delete_prefix("[").delete_suffix("]")
      IPAddr.new(candidate)
      true
    rescue IPAddr::InvalidAddressError
      false
    end
  end
end
