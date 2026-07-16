# frozen_string_literal: true

require "digest"

module HoneycombSecurityLint
  module Evidence
    VERDICTS = {
      "pass" => "Security lint passed",
      "fail" => "Security lint found blocking evidence",
      "awaiting_maintainer" => "Security lint awaits the safe-to-validate maintainer gate",
      "expired" => "Security lint evidence expired after the honeycomb changed",
      "unchanged" => "Security lint found no changed honeycomb versions",
      "error" => "Security lint failed closed because analysis was incomplete"
    }.freeze

    module_function

    def finalize(document)
      evidence = copy(document)
      evidence.fetch("packages").each { |entry| finalize_package(entry) }
      evidence["totals"] = sum_counts(evidence.fetch("packages"))
      evidence["state"] = aggregate_state(evidence)
      evidence["verdict"] = VERDICTS.fetch(evidence.fetch("state"))
      evidence["artifact_digest"] = nil
      evidence["artifact_digest"] = Digest::SHA256.hexdigest(Contracts.digestable_evidence(evidence))
      Contracts.validate_evidence(evidence)
      evidence
    end

    def apply_approvals(preliminary, approvals)
      evidence = copy(preliminary)
      reviewed_digest = evidence.fetch("artifact_digest")
      evidence.fetch("packages").each do |entry|
        approval = matching_approval(entry, evidence.fetch("head_sha"), reviewed_digest, approvals)
        next unless approval

        approved = approval.fetch("approved_suppressions")
        entry.fetch("findings").each do |finding|
          next unless finding["disposition"] == "hard"
          next unless finding["request"].is_a?(Hash)
          next unless approved.include?(finding.fetch("fingerprint"))

          finding["disposition"] = "downgraded"
          finding["approval"] = approval_reference(approval)
        end
        entry.fetch("suppressions").each do |suppression|
          next unless approved.include?(suppression.fetch("fingerprint"))
          next unless entry.fetch("findings").any? do |finding|
            finding["fingerprint"] == suppression["fingerprint"] && finding["disposition"] == "downgraded"
          end

          suppression["status"] = "approved"
          suppression["approval"] = approval_reference(approval)
        end
      end
      finalize(evidence)
    end

    def finalize_package(entry)
      validator = entry.fetch("validator_findings")
      findings = entry.fetch("findings")
      hard = validator.count { |finding| finding["severity"] == "error" } +
             findings.count { |finding| finding["disposition"] == "hard" }
      advisory = validator.count { |finding| %w[warning info].include?(finding["severity"]) } +
                 findings.count { |finding| finding["disposition"] == "advisory" }
      downgraded = findings.count { |finding| finding["disposition"] == "downgraded" }
      entry["counts"] = {"hard" => hard, "advisory" => advisory, "downgraded" => downgraded}
      entry["verdict"] = if findings.any? { |finding| finding["category"] == "operational" }
                           "error"
                         elsif hard.positive?
                           "fail"
                         else
                           "pass"
                         end
    end

    def sum_counts(packages)
      Contracts::COUNT_KEYS.to_h do |key|
        [key, packages.sum { |entry| entry.fetch("counts").fetch(key) }]
      end
    end

    def aggregate_state(evidence)
      packages = evidence.fetch("packages")
      return evidence.fetch("state") if packages.empty?
      return "error" if packages.any? { |entry| entry["verdict"] == "error" }
      return "fail" if packages.any? { |entry| entry["verdict"] == "fail" }

      "pass"
    end

    def matching_approval(entry, head_sha, digest, approvals)
      identity = entry.fetch("identity")
      Array(approvals).find do |approval|
        approval["decision"] == "approved" &&
          approval.values_at("name", "version", "path", "release_sha256", "head_sha", "evidence_digest") ==
          [identity["name"], identity["version"], identity["path"], identity["release_sha256"], head_sha, digest]
      end
    end

    def approval_reference(approval)
      {
        "reviewer" => approval.fetch("reviewer"),
        "reviewed_at" => approval.fetch("reviewed_at"),
        "review_url" => approval.fetch("review_url"),
        "evidence_digest" => approval.fetch("evidence_digest")
      }
    end

    def copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
