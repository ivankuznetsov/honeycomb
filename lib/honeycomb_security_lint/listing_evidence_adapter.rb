# frozen_string_literal: true

require "time"

module HoneycombSecurityLint
  module ListingEvidenceAdapter
    module_function

    def build(lint_evidence:, approvals:, checked_at:, tier:)
      evidence = Contracts.plain_copy(lint_evidence)
      Contracts.validate_evidence(evidence)
      raise Contracts::Invalid, "lint evidence content digest is invalid" unless Contracts.artifact_digest_valid?(evidence)
      approval_records = Contracts.plain_copy(Array(approvals))
      Contracts.validate_approvals({"schema" => Contracts::APPROVAL_SCHEMA, "approvals" => approval_records})
      validate_checked_at!(checked_at)
      unless tier.is_a?(String) && HoneycombRegistry::ListingEvidence::TIER_PATTERN.match?(tier)
        raise Contracts::Invalid, "listing tier is invalid"
      end

      packages = evidence.fetch("packages")
      approvals_by_path = validate_approval_bindings!(evidence, packages, approval_records)
      records = packages.map do |package|
        identity = package.fetch("identity")
        approval = approvals_by_path[identity.fetch("path")]
        {
          "name" => identity.fetch("name"), "version" => identity.fetch("version"),
          "tier" => tier,
          "lint" => lint_verdict(evidence, package, checked_at),
          "approval" => approval_verdict(approval)
        }
      end
      {
        "schema" => HoneycombRegistry::ListingEvidence::SCHEMA,
        "records" => records.sort_by { |record| [record.fetch("name"), HoneycombRegistry::SemVer.parse(record.fetch("version"))] }
      }
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
        by_path[path] = approval
        approved = approval.fetch("approved_suppressions")
        if approval["decision"] == "denied" && !approved.empty?
          errors << "approvals[#{index}] cannot approve suppressions with a denied decision"
        end
        downgraded = package.fetch("findings").select { |finding| finding["disposition"] == "downgraded" }
        downgraded_fingerprints = downgraded.map { |finding| finding.fetch("fingerprint") }.sort
        unless downgraded_fingerprints == approved.sort
          errors << "approvals[#{index}] suppression set does not match downgraded evidence"
        end
        validate_suppression_references!(package, approval, downgraded, errors, index)
        expected_digest = approved.empty? ? evidence.fetch("artifact_digest") : preliminary_digest
        unless approval["evidence_digest"] == expected_digest
          errors << "approvals[#{index}] reviewed evidence digest is stale"
        end
      end

      packages.each do |package|
        next unless package.fetch("findings").any? { |finding| finding["disposition"] == "downgraded" }
        errors << "#{package.dig("identity", "path")} has downgraded evidence without a current approval" unless by_path.key?(package.dig("identity", "path"))
      end
      raise Contracts::Invalid, errors unless errors.empty?

      by_path
    end

    def validate_suppression_references!(package, approval, downgraded, errors, approval_index)
      expected_reference = {
        "reviewer" => approval.fetch("reviewer"), "reviewed_at" => approval.fetch("reviewed_at"),
        "review_url" => approval.fetch("review_url"), "evidence_digest" => approval.fetch("evidence_digest")
      }
      downgraded.each do |finding|
        fingerprint = finding.fetch("fingerprint")
        unless finding["original_severity"] == "hard" && finding["request"].is_a?(Hash) &&
               finding["approval"] == expected_reference
          errors << "approvals[#{approval_index}] does not match the preliminary finding #{fingerprint}"
        end
        suppression = package.fetch("suppressions").find { |entry| entry["fingerprint"] == fingerprint }
        unless suppression && suppression["status"] == "approved" && suppression["approval"] == expected_reference
          errors << "approvals[#{approval_index}] does not match the suppression request #{fingerprint}"
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
      return {"status" => "pending"} unless approval

      {
        "status" => approval.fetch("decision"),
        "release_sha256" => approval.fetch("release_sha256"),
        "head_sha" => approval.fetch("head_sha"), "reviewer" => approval.fetch("reviewer"),
        "reviewed_at" => approval.fetch("reviewed_at"), "review_url" => approval.fetch("review_url")
      }
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
