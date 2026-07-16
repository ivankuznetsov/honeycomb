# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintValidatorAdapterTest < Minitest::Test
  def adapter(stdout:, stderr: "", exit_status: 0)
    HoneycombSecurityLint::ValidatorAdapter.new(
      root: ROOT,
      executor: ->(_argv) { [stdout, stderr, exit_status] }
    )
  end

  def test_preserves_validator_findings_for_supported_exits
    finding = [{"path" => "packages/example/1.0.0/manifest.yml", "code" => "schema.bad", "message" => "bad", "severity" => "error"}]
    result = adapter(stdout: JSON.generate(finding), exit_status: 1).validate("packages/example/1.0.0")

    refute result.error?
    assert_equal 1, result.exit_status
    assert_equal finding, result.findings
  end

  def test_empty_success_passes_through
    result = adapter(stdout: "[]", exit_status: 0).validate("packages/example/1.0.0")

    refute result.error?
    assert_empty result.findings
  end

  def test_invokes_the_production_validator_contract
    in_tmpdir do |root|
      package = install_valid_fixture(root)
      _stdout, stderr, status = capture_command(
        File.join(ROOT, "script", "honeycomb-manifest"), "--root", root, package
      )
      assert_equal 0, status.exitstatus, stderr
      result = HoneycombSecurityLint::ValidatorAdapter.new(
        root: root, executable: File.join(ROOT, "script", "honeycomb-validate")
      ).validate(package)

      refute result.error?, result.operational_error
      assert_equal 0, result.exit_status, result.findings.inspect
      assert result.findings.all? { |finding| finding.keys.sort == %w[code message path severity] }
    end
  end

  def test_exit_two_malformed_json_and_schema_drift_fail_operationally
    cases = [
      adapter(stdout: "[]", stderr: "boom", exit_status: 2),
      adapter(stdout: "not json"),
      adapter(stdout: JSON.generate([{"path" => "x", "code" => "x", "message" => "x", "severity" => "fatal"}]))
    ]
    cases.each do |candidate|
      result = candidate.validate("packages/example/1.0.0")
      assert result.error?
      assert_equal 2, result.exit_status
    end
  end
end
