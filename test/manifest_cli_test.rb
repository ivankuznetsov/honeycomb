# frozen_string_literal: true

require_relative "test_helper"

class ManifestCliTest < Minitest::Test
  SCRIPT = File.join(ROOT, "script", "honeycomb-manifest")

  def test_generate_and_check_one_package_from_another_directory
    in_tmpdir do |root|
      package = install_valid_fixture(root)
      stdout, stderr, status = capture_command(SCRIPT, "--root", root, package,
                                                chdir: File.dirname(root))
      assert status.success?, [stdout, stderr].join("\n")

      before = File.binread(File.join(package, "manifest.yml"))
      stdout, stderr, status = capture_command(SCRIPT, "--root", root, "--check", package,
                                                chdir: File.dirname(root))
      assert status.success?, [stdout, stderr].join("\n")
      assert_equal before, File.binread(File.join(package, "manifest.yml"))
    end
  end

  def test_all_mode_and_invocation_failures_have_distinct_exits
    in_tmpdir do |root|
      install_valid_fixture(root)
      _stdout, _stderr, status = capture_command(SCRIPT, "--root", root, "--all")
      assert_equal 0, status.exitstatus

      _stdout, _stderr, status = capture_command(SCRIPT, "--root", root, "--all", "extra")
      assert_equal 2, status.exitstatus
    end
  end

  def test_check_reports_drift_and_never_writes
    in_tmpdir do |root|
      package = install_valid_fixture(root)
      original = File.binread(File.join(package, "manifest.yml"))

      stdout, _stderr, status = capture_command(SCRIPT, "--root", root, "--check", package)
      assert_equal 1, status.exitstatus
      assert_includes stdout, "manifest.drift"
      assert_equal original, File.binread(File.join(package, "manifest.yml"))
    end
  end
end
