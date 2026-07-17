# frozen_string_literal: true

require_relative "test_helper"

class EndToEndTest < Minitest::Test
  MANIFEST = File.join(ROOT, "script", "honeycomb-manifest")
  VALIDATE = File.join(ROOT, "script", "honeycomb-validate")
  CATALOG = File.join(ROOT, "script", "honeycomb-catalog")
  EVIDENCE = File.join(ROOT, "test", "fixtures", "listing-evidence", "passing.json")

  def test_author_to_approved_catalog_flow_is_repeatable_from_another_directory
    in_tmpdir do |root|
      package = install_valid_fixture(root)
      outside = File.dirname(root)

      stdout, stderr, status = capture_command(MANIFEST, "--root", root, package, chdir: outside)
      assert_equal 0, status.exitstatus, [stdout, stderr].join("\n")
      manifest_bytes = File.binread(File.join(package, "manifest.yml"))
      assert_equal File.binread(fixture_path("expected", "manifest.yml")), manifest_bytes

      stdout, stderr, status = capture_command(
        MANIFEST, "--root", root, "--check", "--all", chdir: outside
      )
      assert_equal 0, status.exitstatus, [stdout, stderr].join("\n")

      stdout, stderr, status = capture_command(
        VALIDATE, "--root", root, "--json", package, chdir: outside
      )
      assert_equal 0, status.exitstatus, stderr
      assert_kind_of Array, JSON.parse(stdout)

      stdout, stderr, status = capture_command(
        VALIDATE, "--root", root, "--json", "--require-hive", "--all", chdir: outside
      )
      runtime = begin
        HoneycombRegistry::HiveCompatibility.load_runtime
      rescue LoadError
        nil
      end
      assert_equal(runtime ? 0 : 1, status.exitstatus, [stdout, stderr].join("\n"))
      unless runtime
        assert JSON.parse(stdout).any? { |finding| finding["code"] == "hive.missing" }
      end

      stdout, stderr, status = capture_command(
        CATALOG, "--root", root, "--evidence", EVIDENCE, chdir: outside
      )
      assert_equal 0, status.exitstatus, [stdout, stderr].join("\n")
      catalog_bytes = File.binread(File.join(root, "catalog.json"))
      assert_equal 1, JSON.parse(catalog_bytes).fetch("entries").length

      stdout, stderr, status = capture_command(
        CATALOG, "--root", root, "--check", "--evidence", EVIDENCE, chdir: outside
      )
      assert_equal 0, status.exitstatus, [stdout, stderr].join("\n")
      assert_equal catalog_bytes, File.binread(File.join(root, "catalog.json"))
      assert_equal manifest_bytes, File.binread(File.join(package, "manifest.yml"))
    end
  end

  def test_payload_tamper_breaks_manifest_validation_and_catalog_checks_without_writes
    in_tmpdir do |root|
      package = install_valid_fixture(root)
      assert_equal 0, capture_command(MANIFEST, "--root", root, package).last.exitstatus
      assert_equal 0, capture_command(CATALOG, "--root", root, "--evidence", EVIDENCE).last.exitstatus
      manifest_before = File.binread(File.join(package, "manifest.yml"))
      catalog_before = File.binread(File.join(root, "catalog.json"))
      File.open(File.join(package, "README.md"), "a") { |file| file << "tamper\n" }

      _stdout, _stderr, status = capture_command(MANIFEST, "--root", root, "--check", package)
      assert_equal 1, status.exitstatus
      _stdout, _stderr, status = capture_command(VALIDATE, "--root", root, "--json", package)
      assert_equal 1, status.exitstatus
      _stdout, _stderr, status = capture_command(
        CATALOG, "--root", root, "--check", "--evidence", EVIDENCE
      )
      assert_equal 1, status.exitstatus
      assert_equal manifest_before, File.binread(File.join(package, "manifest.yml"))
      assert_equal catalog_before, File.binread(File.join(root, "catalog.json"))
    end
  end

  def test_real_registry_matches_all_committed_derived_artifacts
    stdout, stderr, status = capture_command(MANIFEST, "--check", "--all")
    assert_equal 0, status.exitstatus, [stdout, stderr].join("\n")

    stdout, stderr, status = capture_command(VALIDATE, "--all", "--json")
    assert_equal 0, status.exitstatus, stderr
    refute JSON.parse(stdout).any? { |finding| finding["severity"] == "error" }

    stdout, stderr, status = capture_command(
      CATALOG, "--check", "--evidence", fixture_path("listing-evidence", "empty.json")
    )
    assert_equal 0, status.exitstatus, [stdout, stderr].join("\n")
  end
end
