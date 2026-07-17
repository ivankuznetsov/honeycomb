# frozen_string_literal: true

require_relative "test_helper"

class ListingEvidenceTest < Minitest::Test
  def test_loads_strict_normalized_records
    result = HoneycombRegistry::ListingEvidence.load(
      fixture_path("listing-evidence", "passing.json")
    )

    refute result.findings.errors?, result.findings.to_h.inspect
    assert_equal 1, result.records.length
    assert HoneycombRegistry::ListingEvidence.eligible?(result.records.first)
  end

  def test_rejects_duplicate_json_keys_unknown_fields_and_duplicate_records
    in_tmpdir do |root|
      duplicate_key = File.join(root, "duplicate-key.json")
      File.write(duplicate_key, '{"schema":"one","schema":"two","records":[]}')
      assert_includes HoneycombRegistry::ListingEvidence.load(duplicate_key).findings.codes,
                      "evidence.duplicate_key"

      unknown = JSON.parse(File.read(fixture_path("listing-evidence", "passing.json")))
      unknown["records"][0]["surprise"] = true
      unknown_path = File.join(root, "unknown.json")
      File.write(unknown_path, JSON.generate(unknown))
      assert_includes HoneycombRegistry::ListingEvidence.load(unknown_path).findings.codes,
                      "evidence.unknown_key"

      duplicate = JSON.parse(File.read(fixture_path("listing-evidence", "passing.json")))
      duplicate["records"] << duplicate["records"].first
      duplicate_path = File.join(root, "duplicate.json")
      File.write(duplicate_path, JSON.generate(duplicate))
      assert_includes HoneycombRegistry::ListingEvidence.load(duplicate_path).findings.codes,
                      "evidence.duplicate_record"

      unsorted = JSON.parse(File.read(fixture_path("listing-evidence", "passing.json")))
      older = Marshal.load(Marshal.dump(unsorted["records"].first))
      older["version"] = "0.9.0"
      unsorted["records"] << older
      unsorted_path = File.join(root, "unsorted.json")
      File.write(unsorted_path, JSON.generate(unsorted))
      assert_includes HoneycombRegistry::ListingEvidence.load(unsorted_path).findings.codes,
                      "evidence.noncanonical_records"
    end
  end

  def test_pending_and_denied_records_are_well_formed_but_ineligible
    base = JSON.parse(File.read(fixture_path("listing-evidence", "passing.json"))).fetch("records").first
    pending = Marshal.load(Marshal.dump(base))
    pending["approvals"] = []
    denied = Marshal.load(Marshal.dump(base))
    denied["approvals"][0]["status"] = "denied"

    refute HoneycombRegistry::ListingEvidence.eligible?(pending)
    refute HoneycombRegistry::ListingEvidence.eligible?(denied)
  end

  def test_rejects_malformed_identity_timestamp_and_url_fields
    base = JSON.parse(File.read(fixture_path("listing-evidence", "passing.json")))
    mutations = [
      ->(data) { data["records"][0]["lint"]["head_sha"] = "not-a-sha" },
      ->(data) { data["records"][0]["approvals"][0]["reviewed_at"] = "yesterday" },
      ->(data) { data["records"][0]["approvals"][0]["review_url"] = "javascript:bad" }
    ]

    mutations.each_with_index do |mutation, index|
      in_tmpdir do |root|
        data = Marshal.load(Marshal.dump(base))
        mutation.call(data)
        path = File.join(root, "bad-#{index}.json")
        File.write(path, JSON.generate(data))
        assert HoneycombRegistry::ListingEvidence.load(path).findings.errors?
      end
    end
  end

  def test_validates_independent_tier_lifecycle_history_and_advisories
    base = JSON.parse(File.read(fixture_path("listing-evidence", "passing.json")))
    record = base.fetch("records").first
    record["release_tier"] = "verified"
    record["current_tier"] = "community"
    record["state"] = "revoked"
    record["history"] = [
      {
        "kind" => "tier", "from" => "verified", "to" => "community",
        "changed_at" => "2026-07-17T08:00:00Z", "actor" => "maintainer-one",
        "reason" => "Verification policy changed",
        "url" => "https://example.test/history/tier"
      },
      {
        "kind" => "state", "from" => "listed", "to" => "revoked",
        "changed_at" => "2026-07-17T09:00:00Z", "actor" => "maintainer-two",
        "reason" => "Credential theft behavior",
        "url" => "https://example.test/history/revocation"
      }
    ]
    record["advisories"] = [{
      "id" => "HC-2026-001", "title" => "Credential access in instructions",
      "severity" => "critical", "url" => "https://example.test/advisories/HC-2026-001",
      "published_at" => "2026-07-17T09:00:00Z"
    }]
    record["verification"] = verification

    findings = HoneycombRegistry::ListingEvidence.validate_document(base)
    refute findings.errors?, findings.to_h.inspect
    assert HoneycombRegistry::ListingEvidence.eligible?(record)

    identity = record.dig("verification", "signature", "identity")
    record["verification"]["signature"]["identity"] = "https://github.com/attacker/release.yml@refs/tags/v1"
    assert_includes HoneycombRegistry::ListingEvidence.validate_document(base).codes,
                    "evidence.invalid_signature_identity"
    record["verification"]["signature"]["identity"] = identity

    record["history"].reverse!
    assert_includes HoneycombRegistry::ListingEvidence.validate_document(base).codes,
                    "evidence.noncanonical_history"
  end

  def test_verified_and_revoked_states_fail_closed_without_required_evidence
    base = JSON.parse(File.read(fixture_path("listing-evidence", "passing.json")))
    record = base.fetch("records").first
    record["release_tier"] = "verified"
    record["current_tier"] = "verified"
    assert_includes HoneycombRegistry::ListingEvidence.validate_document(base).codes,
                    "evidence.missing_verification"

    record["release_tier"] = "community"
    record["current_tier"] = "community"
    record["state"] = "revoked"
    record["history"] = [{
      "kind" => "state", "from" => "listed", "to" => "revoked",
      "changed_at" => "2026-07-17T09:00:00Z", "actor" => "maintainer",
      "reason" => "Unsafe behavior", "url" => "https://example.test/history/revocation"
    }]
    assert_includes HoneycombRegistry::ListingEvidence.validate_document(base).codes,
                    "evidence.missing_advisory"
  end

  def verification
    {
      "archive_sha256" => "b" * 64,
      "signature" => {
        "identity" => "https://github.com/hive-sh/honeycomb/.github/workflows/release.yml@refs/tags/v1.0.0",
        "issuer" => "https://token.actions.githubusercontent.com",
        "url" => "https://search.sigstore.dev/entry/123"
      },
      "attestation" => {
        "repository" => "hive-sh/honeycomb",
        "workflow" => "hive-sh/honeycomb/.github/workflows/release.yml@refs/tags/v1.0.0",
        "url" => "https://github.com/hive-sh/honeycomb/attestations/123"
      },
      "verified_at" => "2026-07-16T12:00:00Z"
    }
  end
end
