# frozen_string_literal: true

require_relative "test_helper"

class ReleaseVerificationTest < Minitest::Test
  def test_archive_identity_changes_when_any_signed_member_or_release_metadata_changes
    manifest = HoneycombRegistry::SafeYAML.load_file(fixture_path("expected", "manifest.yml"))
    original = HoneycombRegistry::ReleaseVerification.archive_sha256(manifest)
    changed_member = Marshal.load(Marshal.dump(manifest))
    changed_member["files"][changed_member["files"].keys.first] = "f" * 64
    changed_release = Marshal.load(Marshal.dump(manifest))
    changed_release["release_sha256"] = "e" * 64

    refute_equal original, HoneycombRegistry::ReleaseVerification.archive_sha256(changed_member)
    refute_equal original, HoneycombRegistry::ReleaseVerification.archive_sha256(changed_release)
    assert_match(/\A[0-9a-f]{64}\z/, original)
  end
end
