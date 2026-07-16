# frozen_string_literal: true

require_relative "test_helper"

class ValidatorCliTest < Minitest::Test
  SCRIPT = File.join(ROOT, "script", "honeycomb-validate")

  def canonical_package(root)
    package = HoneycombRegistry::Package.new(install_valid_fixture(root), root: root)
    HoneycombRegistry::Manifest.generate(package)
    package
  end

  def test_json_one_and_all_modes_emit_exact_public_shape
    in_tmpdir do |root|
      package = canonical_package(root)
      stdout, stderr, status = capture_command(SCRIPT, "--root", root, "--json", package.path,
                                                chdir: File.dirname(root))
      assert_equal 0, status.exitstatus, stderr
      findings = JSON.parse(stdout)
      findings.each { |finding| assert_equal %w[path code message severity], finding.keys }

      stdout, stderr, status = capture_command(SCRIPT, "--root", root, "--json", "--all")
      assert_equal 0, status.exitstatus, stderr
      assert_kind_of Array, JSON.parse(stdout)
    end
  end

  def test_validation_errors_exit_one_without_writing
    in_tmpdir do |root|
      package = canonical_package(root)
      File.write(File.join(package.path, "extra.txt"), "extra")
      before = File.binread(package.manifest_path)

      stdout, _stderr, status = capture_command(SCRIPT, "--root", root, "--json", package.path)
      assert_equal 1, status.exitstatus
      assert JSON.parse(stdout).any? { |finding| finding["code"] == "integrity.unrecorded_file" }
      assert_equal before, File.binread(package.manifest_path)
    end
  end

  def test_invocation_failure_exits_two_and_keeps_json_stdout_valid
    in_tmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "packages"))
      stdout, stderr, status = capture_command(SCRIPT, "--root", root, "--json", "missing")

      assert_equal 2, status.exitstatus
      finding = JSON.parse(stdout).fetch(0)
      assert_equal %w[path code message severity], finding.keys
      assert_equal "invocation.error", finding["code"]
      refute_empty stderr
    end
  end
end
