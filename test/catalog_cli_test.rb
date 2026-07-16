# frozen_string_literal: true

require_relative "test_helper"

class CatalogCliTest < Minitest::Test
  SCRIPT = File.join(ROOT, "script", "honeycomb-catalog")

  def test_generate_and_check_empty_catalog_are_byte_stable
    in_tmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "packages"))
      evidence = fixture_path("listing-evidence", "empty.json")
      output = File.join(root, "catalog.json")

      stdout, stderr, status = capture_command(
        SCRIPT, "--root", root, "--output", output, "--evidence", evidence
      )
      assert_equal 0, status.exitstatus, [stdout, stderr].join("\n")
      first = File.binread(output)

      stdout, stderr, status = capture_command(
        SCRIPT, "--root", root, "--output", output, "--check", "--evidence", evidence
      )
      assert_equal 0, status.exitstatus, [stdout, stderr].join("\n")
      assert_equal first, File.binread(output)
    end
  end

  def test_check_detects_drift_without_writing_and_evidence_is_required
    in_tmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "packages"))
      output = File.join(root, "catalog.json")
      File.write(output, "stale\n")
      evidence = fixture_path("listing-evidence", "empty.json")

      stdout, _stderr, status = capture_command(
        SCRIPT, "--root", root, "--output", output, "--check", "--evidence", evidence
      )
      assert_equal 1, status.exitstatus
      assert_includes stdout, "catalog.drift"
      assert_equal "stale\n", File.read(output)

      _stdout, _stderr, status = capture_command(SCRIPT, "--root", root)
      assert_equal 2, status.exitstatus
    end
  end

  def test_malformed_evidence_does_not_replace_existing_catalog
    in_tmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "packages"))
      output = File.join(root, "catalog.json")
      File.write(output, "preserve\n")
      evidence = File.join(root, "bad.json")
      File.write(evidence, "not json")

      _stdout, _stderr, status = capture_command(
        SCRIPT, "--root", root, "--output", output, "--evidence", evidence
      )
      assert_equal 1, status.exitstatus
      assert_equal "preserve\n", File.read(output)
    end
  end
end
