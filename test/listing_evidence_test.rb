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
    end
  end

  def test_pending_and_denied_records_are_well_formed_but_ineligible
    base = JSON.parse(File.read(fixture_path("listing-evidence", "passing.json"))).fetch("records").first
    pending = Marshal.load(Marshal.dump(base))
    pending["approval"] = {"status" => "pending"}
    denied = Marshal.load(Marshal.dump(base))
    denied["approval"]["status"] = "denied"

    refute HoneycombRegistry::ListingEvidence.eligible?(pending)
    refute HoneycombRegistry::ListingEvidence.eligible?(denied)
  end

  def test_rejects_malformed_identity_timestamp_and_url_fields
    base = JSON.parse(File.read(fixture_path("listing-evidence", "passing.json")))
    mutations = [
      ->(data) { data["records"][0]["lint"]["head_sha"] = "not-a-sha" },
      ->(data) { data["records"][0]["approval"]["reviewed_at"] = "yesterday" },
      ->(data) { data["records"][0]["approval"]["review_url"] = "javascript:bad" }
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
end
