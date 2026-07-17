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

  def test_timeout_kills_and_reaps_the_validator_process_group
    in_tmpdir do |root|
      executable = File.join(root, "sleeping-validator.rb")
      pid_file = File.join(root, "validator.pid")
      File.write(executable, <<~RUBY)
        File.write(ARGV.last, Process.pid.to_s)
        sleep 30
      RUBY
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = HoneycombSecurityLint::ValidatorAdapter.new(
        root: root, executable: executable, timeout_seconds: 0.1
      ).validate(pid_file)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert result.error?
      assert_equal "validator timed out", result.operational_error
      assert_operator elapsed, :<, 2
      pid = Integer(File.read(pid_file))
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  end
end
