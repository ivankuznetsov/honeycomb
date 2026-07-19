# frozen_string_literal: true

require "time"

module HoneycombSecurityLint
  module ListingEvidenceAdapter
    module_function

    TRUST_KEYS = %w[release_tier current_tier state verification history advisories].freeze

    def build(lint_evidence:, approvals:, checked_at:, release_tier:, trust: {})
      evidence = Contracts.plain_copy(lint_evidence)
      Contracts.validate_evidence(evidence)
      raise Contracts::Invalid, "lint evidence content digest is invalid" unless Contracts.artifact_digest_valid?(evidence)
      approval_records = Contracts.plain_copy(Array(approvals))
      Contracts.validate_approvals({"schema" => Contracts::APPROVAL_SCHEMA, "approvals" => approval_records})
      validate_checked_at!(checked_at)
      unless HoneycombRegistry::ListingEvidence::TIERS.include?(release_tier)
        raise Contracts::Invalid, "listing release tier is invalid"
      end
      raise Contracts::Invalid, "listing trust projection must be an object" unless trust.is_a?(Hash)

      packages = evidence.fetch("packages")
      approvals_by_path = validate_approval_bindings!(evidence, packages, approval_records)
      records = packages.map do |package|
        identity = package.fetch("identity")
        path = identity.fetch("path")
        projection = trust_projection(release_tier, trust.fetch(path, {}))
        {
          "name" => identity.fetch("name"), "version" => identity.fetch("version"),
          "release_tier" => projection.fetch("release_tier"),
          "current_tier" => projection.fetch("current_tier"),
          "permission_risk" => package.dig("requested_permissions", "risk"),
          "state" => projection.fetch("state"),
          "lint" => lint_verdict(evidence, package, checked_at),
          "approvals" => Array(approvals_by_path[path]).map { |approval| approval_verdict(approval) },
          "verification" => projection.fetch("verification"),
          "history" => projection.fetch("history"),
          "advisories" => projection.fetch("advisories")
        }
      end
      document = {
        "schema" => HoneycombRegistry::ListingEvidence::SCHEMA,
        "records" => records.sort_by { |record| [record.fetch("name"), HoneycombRegistry::SemVer.parse(record.fetch("version"))] }
      }
      findings = HoneycombRegistry::ListingEvidence.validate_document(document)
      if findings.errors?
        raise Contracts::Invalid, findings.to_h.map { |finding| "#{finding.fetch("path")}: #{finding.fetch("message")}" }
      end
      document
    end

    def validate_approval_bindings!(evidence, packages, approvals)
      errors = []
      by_path = {}
      preliminary_digest = reconstructed_preliminary_digest(evidence)
      approvals.each_with_index do |approval, index|
        package = packages.find do |entry|
          identity = entry.fetch("identity")
          approval.values_at("name", "version", "path", "release_sha256", "head_sha") ==
            [identity["name"], identity["version"], identity["path"], identity["release_sha256"], evidence["head_sha"]]
        end
        unless package
          errors << "approvals[#{index}] is stale or does not identify current lint evidence"
          next
        end
        path = package.dig("identity", "path")
        by_path[path] ||= []
        by_path[path] << approval
        approved = approval.fetch("approved_suppressions")
        if approval["decision"] == "denied" && !approved.empty?
          errors << "approvals[#{index}] cannot approve suppressions with a denied decision"
        end
        downgraded = package.fetch("findings").select { |finding| finding["disposition"] == "downgraded" }
        downgraded_fingerprints = downgraded.map { |finding| finding.fetch("fingerprint") }
        unless (approved - downgraded_fingerprints).empty?
          errors << "approvals[#{index}] suppression set is not present in downgraded evidence"
        end
        expected_digest = approved.empty? ? evidence.fetch("artifact_digest") : preliminary_digest
        unless approval["evidence_digest"] == expected_digest
          errors << "approvals[#{index}] reviewed evidence digest is stale"
        end
      end

      packages.each do |package|
        path = package.dig("identity", "path")
        downgraded = package.fetch("findings").select { |finding| finding["disposition"] == "downgraded" }
        next if downgraded.empty?
        approved = Array(by_path[path]).flat_map { |approval| approval.fetch("approved_suppressions") }.uniq.sort
        expected = downgraded.map { |finding| finding.fetch("fingerprint") }.uniq.sort
        errors << "#{path} has downgraded evidence without exact current approvals" unless approved == expected
        validate_suppression_references!(package, Array(by_path[path]), downgraded, errors)
      end
      raise Contracts::Invalid, errors unless errors.empty?

      by_path.each_value { |values| values.sort_by! { |approval| approval.fetch("reviewer").downcase } }
      by_path
    end

    def validate_suppression_references!(package, approvals, downgraded, errors)
      downgraded.each do |finding|
        fingerprint = finding.fetch("fingerprint")
        references = approvals.select do |approval|
          approval["decision"] == "approved" && approval.fetch("approved_suppressions").include?(fingerprint)
        end.map do |approval|
          {
            "reviewer" => approval.fetch("reviewer"), "reviewed_at" => approval.fetch("reviewed_at"),
            "review_url" => approval.fetch("review_url"), "evidence_digest" => approval.fetch("evidence_digest")
          }
        end
        unless finding["original_severity"] == "hard" && finding["request"].is_a?(Hash) &&
               references.include?(finding["approval"])
          errors << "current approvals do not match the preliminary finding #{fingerprint}"
        end
        suppression = package.fetch("suppressions").find { |entry| entry["fingerprint"] == fingerprint }
        unless suppression && suppression["status"] == "approved" && references.include?(suppression["approval"])
          errors << "current approvals do not match the suppression request #{fingerprint}"
        end
      end
    end

    def reconstructed_preliminary_digest(evidence)
      return evidence.fetch("artifact_digest") unless evidence.fetch("packages").any? do |package|
        package.fetch("findings").any? { |finding| finding["disposition"] == "downgraded" }
      end

      preliminary = Contracts.plain_copy(evidence)
      preliminary.fetch("packages").each do |package|
        package.fetch("findings").each do |finding|
          next unless finding["disposition"] == "downgraded"
          finding["disposition"] = "hard"
          finding["approval"] = nil
        end
        package.fetch("suppressions").each do |suppression|
          next unless suppression["status"] == "approved"
          suppression["status"] = "requested"
          suppression["approval"] = nil
        end
      end
      Evidence.finalize(preliminary).fetch("artifact_digest")
    end

    def lint_verdict(evidence, package, checked_at)
      status = evidence["state"] == "pass" && package["verdict"] == "pass" ? "pass" : "fail"
      {
        "status" => status,
        "release_sha256" => package.dig("identity", "release_sha256"),
        "head_sha" => evidence.fetch("head_sha"), "checked_at" => checked_at
      }
    end

    def approval_verdict(approval)
      {
        "status" => approval.fetch("decision"),
        "authority" => approval.fetch("authority", "independent"),
        "release_sha256" => approval.fetch("release_sha256"),
        "head_sha" => approval.fetch("head_sha"), "reviewer" => approval.fetch("reviewer"),
        "reviewed_at" => approval.fetch("reviewed_at"), "review_url" => approval.fetch("review_url"),
        "evidence_digest" => approval.fetch("evidence_digest")
      }
    end

    def trust_projection(release_tier, override)
      unless override.is_a?(Hash) && (override.keys - TRUST_KEYS).empty?
        raise Contracts::Invalid, "listing trust projection contains unknown fields"
      end
      {
        "release_tier" => release_tier,
        "current_tier" => release_tier,
        "state" => "listed",
        "verification" => nil,
        "history" => [],
        "advisories" => []
      }.merge(Contracts.plain_copy(override))
    end

    def validate_checked_at!(value)
      unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
        raise Contracts::Invalid, "lint checked_at must be RFC 3339 with timezone"
      end
      Time.iso8601(value)
    rescue ArgumentError
      raise Contracts::Invalid, "lint checked_at must be a valid RFC 3339 timestamp"
    end
  end
end
