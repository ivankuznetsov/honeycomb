# frozen_string_literal: true

require "digest"

module HoneycombSecurityLint
  class Runner
    Result = Struct.new(:evidence, :json, :exit_status, keyword_init: true)

    def initialize(root:, context:, policy_path: nil, approvals: [], change_set: nil, validator: nil)
      @root = File.expand_path(root)
      @context = context.transform_keys(&:to_sym)
      @policy = Policy.load(policy_path || File.join(@root, "policy", "security-lint.yml"))
      @approvals = approvals
      @change_set = change_set || ChangeSet.new(root: @root)
      @validator = validator || ValidatorAdapter.new(root: @root)
      @scanner = SecretPiiScanner.new(max_findings: @policy.limits.fetch("max_findings"))
    end

    def run
      state = non_analysis_state
      return finish(base_document(state, [])) if state

      if @context[:label_sha] != @context[:head_sha]
        expired = base_document("expired", [])
        expired["event"]["gate"] = "expired"
        return finish(expired)
      end

      changed = @change_set.between(@context.fetch(:base_sha), @context.fetch(:head_sha))
      return finish(base_document("unchanged", [])) if changed.version_roots.empty?

      existing = Array(changed.existing_version_roots)
      packages = changed.version_roots.map do |version_root|
        package = analyze(version_root)
        if existing.include?(version_root)
          package.fetch("findings") << generic_finding(
            "package.immutable-version", "integrity", version_root,
            "A package version already present in the base revision is immutable; publish a new SemVer version"
          )
        end
        package
      end
      preliminary = Evidence.finalize(base_document("pass", packages))
      evidence = @approvals.empty? ? preliminary : Evidence.apply_approvals(preliminary, @approvals)
      bounded(evidence)
    rescue ChangeSet::Invalid => e
      finish(error_document("operational.change-set", "Changed honeycombs could not be determined", e.class.name))
    rescue Contracts::Invalid, SystemCallError, IOError => e
      finish(error_document("operational.runner", "Security lint could not complete safely", e.class.name))
    end

    private

    def non_analysis_state
      case @context.fetch(:gate)
      when "required" then "awaiting_maintainer"
      when "expired" then "expired"
      when "unchanged" then "unchanged"
      when "applied" then nil
      else "error"
      end
    end

    def analyze(version_root)
      name, version = version_root.split("/").last(2)
      validator_result = @validator.validate(version_root)
      validator_findings = safe_validator_findings(validator_result.findings)
      findings = []
      operational = false
      if validator_result.error?
        operational = true
        findings << generic_finding("operational.validator", "operational", version_root,
                                    "The production validator did not complete safely")
      end

      files = []
      begin
        files = TextFiles.new(root: @root, limits: @policy.limits).collect(version_root).files
      rescue TextFiles::Invalid
        operational = true
        findings << generic_finding("operational.content-scan", "operational", version_root,
                                    "Honeycomb content could not be scanned completely")
      end

      manifest = load_manifest(files, version_root, findings)
      permissions = manifest["permissions"] if manifest.is_a?(Hash) && manifest["permissions"].is_a?(Hash)
      extension = security_extension(manifest, version_root, findings)
      begin
        findings.concat(@scanner.scan(files))
      rescue SecretPiiScanner::LimitExceeded
        operational = true
        findings << generic_finding("operational.finding-limit", "operational", version_root,
                                    "Honeycomb content produced too many security findings")
      end

      commands = []
      begin
        executable_paths = Array(manifest&.dig("x-hive", "tools")).filter_map do |tool|
          path = tool["path"] if tool.is_a?(Hash)
          "#{version_root}/#{path}" if path.is_a?(String)
        end
        prompt_asset_paths = Array(manifest&.dig("x-hive", "prompt_assets")).filter_map do |asset|
          path = asset["path"] if asset.is_a?(Hash)
          "#{version_root}/#{path}" if path.is_a?(String)
        end
        behavior_paths = executable_paths + prompt_asset_paths
        commands = CommandExtractor.new(max_commands: @policy.limits.fetch("max_commands"))
                                   .extract(
                                     files, version_root: version_root, behavior_paths: behavior_paths,
                                     executable_paths: executable_paths
                                   )
      rescue CommandExtractor::LimitExceeded
        operational = true
        findings << generic_finding("operational.command-limit", "operational", version_root,
                                    "Honeycomb instructions produced too many commands")
      rescue CommandExtractor::Invalid
        findings << generic_finding("instruction.malformed-yaml", "instruction", version_root,
                                    "Instruction YAML could not be parsed safely")
      end
      observations = begin
        NetworkExtractor.new(max_observations: @policy.limits.fetch("max_observations")).extract(commands)
      rescue NetworkExtractor::LimitExceeded
        operational = true
        findings << generic_finding("operational.observation-limit", "operational", version_root,
                                    "Honeycomb instructions produced too many network destinations")
        []
      end
      permission_findings, hosts = PermissionChecker.new(policy: @policy).check(
        commands: commands, observations: observations, permissions: permissions,
        security_extension: extension
      )
      begin
        findings.concat(RuleEngine.new(max_findings: @policy.limits.fetch("max_findings")).analyze(commands))
      rescue RuleEngine::LimitExceeded
        operational = true
        findings << generic_finding("operational.rule-limit", "operational", version_root,
                                    "Honeycomb instructions produced too many deny findings")
      end
      findings.concat(permission_findings)
      suppressions = attach_requests(findings, extension.fetch("suppressions"), version_root)
      findings.sort_by! { |finding| [finding["path"], finding["line"], finding["column"], finding["rule_id"]] }

      identity = {
        "name" => name, "version" => version, "path" => version_root,
        "release_sha256" => release_sha(manifest)
      }
      entry = {
        "identity" => identity,
        "validator_findings" => validator_findings,
        "requested_permissions" => safe_value(permissions),
        "scanned_files" => files.map(&:evidence),
        "commands" => commands.map(&:evidence),
        "hosts" => safe_value(hosts),
        "findings" => findings,
        "suppressions" => suppressions,
        "counts" => {"hard" => 0, "advisory" => 0, "downgraded" => 0},
        "verdict" => operational ? "error" : "pass"
      }
      Evidence.finalize_package(entry)
      entry
    end

    def load_manifest(files, version_root, findings)
      source = files.find { |file| file.path == "#{version_root}/manifest.yml" }
      return nil unless source&.text

      HoneycombRegistry::SafeYAML.load(source.bytes, path: source.path)
    rescue HoneycombRegistry::SafeYAML::Invalid
      findings << generic_finding("manifest.malformed", "manifest", "#{version_root}/manifest.yml",
                                  "Manifest YAML could not be parsed safely")
      nil
    end

    def security_extension(manifest, version_root, findings)
      return {"network_host_reasons" => {}, "suppressions" => []} unless manifest.is_a?(Hash)

      @policy.security_extension(manifest)
    rescue Contracts::Invalid
      findings << generic_finding("manifest.invalid-security-extension", "manifest",
                                  "#{version_root}/manifest.yml",
                                  "The x-security extension is invalid or grants undeclared access")
      {"network_host_reasons" => {}, "suppressions" => []}
    end

    def attach_requests(findings, requests, version_root)
      requests.map do |request|
        matching = findings.find { |finding| finding["fingerprint"] == request["fingerprint"] }
        reason = @scanner.redact_text(request.fetch("reason"))
        if matching
          matching["request"] = {"reason" => reason}
        else
          findings << generic_finding("suppression.orphaned-request", "suppression", version_root,
                                      "A suppression request does not match current evidence",
                                      seed: request.fetch("fingerprint"))
        end
        {
          "fingerprint" => request.fetch("fingerprint"), "reason" => reason,
          "status" => matching ? "requested" : "orphaned", "approval" => nil
        }
      end
    end

    def safe_validator_findings(findings)
      findings.map do |finding|
        {
          "path" => @scanner.redact_text(finding.fetch("path")),
          "code" => Redactor.sanitize_text(finding.fetch("code"), max_bytes: 100),
          "message" => @scanner.redact_text(finding.fetch("message")),
          "severity" => finding.fetch("severity")
        }
      end
    end

    def safe_value(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) do |key, safe|
          safe[@scanner.redact_text(key)] = safe_value(value[key])
        end
      when Array
        value.map { |entry| safe_value(entry) }
      when String
        @scanner.redact_text(value)
      else
        value
      end
    end

    def release_sha(manifest)
      value = manifest["release_sha256"] if manifest.is_a?(Hash)
      value if value.is_a?(String) && Contracts::SHA256_PATTERN.match?(value)
    end

    def generic_finding(rule_id, category, path, message, seed: message)
      {
        "rule_id" => rule_id, "category" => category, "original_severity" => "hard",
        "disposition" => "hard", "path" => Redactor.sanitize_text(path), "line" => 1,
        "column" => 1, "fingerprint" => Digest::SHA256.hexdigest([rule_id, path, seed].join("\0")),
        "redacted_evidence" => "Analysis failed closed", "message" => message,
        "request" => nil, "approval" => nil
      }
    end

    def base_document(state, packages)
      {
        "schema" => Contracts::EVIDENCE_SCHEMA,
        "event" => {
          "action" => @context.fetch(:action), "gate" => @context.fetch(:gate),
          "label_sha" => @context[:label_sha]
        },
        "pull_request" => @context.fetch(:pull_request),
        "base_sha" => @context.fetch(:base_sha), "head_sha" => @context.fetch(:head_sha),
        "run" => {
          "id" => @context.fetch(:run_id), "attempt" => @context.fetch(:run_attempt),
          "workflow" => "Security lint", "repository" => @context.fetch(:repository)
        },
        "artifact_digest" => nil, "state" => state, "packages" => packages,
        "totals" => {"hard" => 0, "advisory" => 0, "downgraded" => 0},
        "verdict" => Evidence::VERDICTS.fetch(state)
      }
    end

    def error_document(rule_id, message, seed)
      document = base_document("error", [])
      document["verdict"] = "#{message} (#{seed})"
      document
    end

    def bounded(evidence)
      json = Contracts.canonical_json(evidence)
      return Result.new(evidence: evidence, json: json, exit_status: exit_for(evidence["state"])) if json.bytesize <= @policy.limits.fetch("max_artifact_bytes")

      finish(error_document("operational.artifact-size", "Security lint evidence exceeded the safe artifact limit", "size"))
    end

    def finish(document)
      evidence = Evidence.finalize(document)
      Result.new(evidence: evidence, json: Contracts.canonical_json(evidence), exit_status: exit_for(evidence["state"]))
    end

    def exit_for(state)
      return 0 if %w[pass unchanged].include?(state)
      return 2 if state == "error"

      1
    end
  end
end
