# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintRunnerTest < Minitest::Test
  SHA = "d" * 40

  FakeChangeSet = Struct.new(:roots) do
    def between(_base, _head)
      HoneycombSecurityLint::ChangeSet::Result.new(version_roots: roots, paths: [])
    end
  end

  FakeValidator = Struct.new(:result) do
    def validate(_path)
      result
    end
  end

  def context(gate: "applied", action: "labeled", label_sha: SHA)
    {
      pull_request: 42, base_sha: "c" * 40, head_sha: SHA, action: action,
      gate: gate, label_sha: label_sha, run_id: 7, run_attempt: 1,
      repository: "hive-sh/honeycomb"
    }
  end

  def validator_result(exit_status: 0, findings: [], operational_error: nil)
    HoneycombSecurityLint::ValidatorAdapter::Result.new(
      exit_status: exit_status, findings: findings, operational_error: operational_error
    )
  end

  def write_honeycomb(root, readme: "# Clean\n")
    version = File.join(root, "packages", "example", "1.0.0")
    FileUtils.mkdir_p(File.join(version, "instructions"))
    File.write(File.join(version, "README.md"), readme)
    File.write(File.join(version, "instructions", "run.md"), "Review the repository.\n")
    File.write(File.join(version, "workflow.yml"), "stages: []\n")
    File.write(File.join(version, "manifest.yml"), <<~YAML)
      schema: honeycomb-manifest/v1
      name: example
      version: 1.0.0
      permissions:
        risk: low
        capabilities: []
        network_hosts: []
        filesystem_read: []
        filesystem_write: []
        secrets: []
      files: {}
      release_sha256: #{"a" * 64}
    YAML
  end

  def runner(root, gate: "applied", validator: validator_result, change_set: nil)
    HoneycombSecurityLint::Runner.new(
      root: root, context: context(gate: gate),
      policy_path: File.join(ROOT, "policy", "security-lint.yml"),
      change_set: change_set || FakeChangeSet.new(["packages/example/1.0.0"]),
      validator: FakeValidator.new(validator)
    )
  end

  def test_awaiting_event_emits_pending_evidence_without_reading_content
    in_tmpdir do |root|
      result = runner(root, gate: "required", change_set: Object.new).run

      assert_equal "awaiting_maintainer", result.evidence.fetch("state")
      assert_equal 1, result.exit_status
      assert_empty result.evidence.fetch("packages")
    end
  end

  def test_clean_and_advisory_only_honeycombs_pass_deterministically
    in_tmpdir do |root|
      write_honeycomb(root, readme: "Contact person@example.test for help.\n")
      first = runner(root).run
      second = runner(root).run

      assert_equal 0, first.exit_status
      assert_equal "pass", first.evidence.fetch("state")
      assert_equal first.json, second.json
      assert_equal 1, first.evidence.dig("totals", "advisory")
      assert HoneycombSecurityLint::Contracts.artifact_digest_valid?(first.evidence)
    end
  end

  def test_collects_validator_and_scanner_findings_without_leaking_secret
    in_tmpdir do |root|
      secret = "ghp_" + "A" * 24
      write_honeycomb(root, readme: "token: #{secret}\n")
      validator_finding = {
        "path" => "packages/example/1.0.0/manifest.yml", "code" => "schema.bad",
        "message" => "manifest is invalid", "severity" => "error"
      }
      result = runner(root, validator: validator_result(exit_status: 1, findings: [validator_finding])).run

      assert_equal 1, result.exit_status
      assert_equal "fail", result.evidence.fetch("state")
      assert_includes result.json, "secret.github-token"
      refute_includes result.json, secret
      assert_equal 2, result.evidence.dig("totals", "hard")
    end
  end

  def test_unsafe_partial_analysis_and_validator_operational_failures_are_errors
    in_tmpdir do |root|
      write_honeycomb(root)
      result = runner(root, validator: validator_result(exit_status: 2, operational_error: "validator timed out")).run

      assert_equal 2, result.exit_status
      assert_equal "error", result.evidence.fetch("state")
      assert_includes result.json, "operational.validator"
    end
  end

  def test_stale_label_sha_expires_without_scanning
    in_tmpdir do |root|
      stale_context = context(label_sha: "e" * 40)
      result = HoneycombSecurityLint::Runner.new(
        root: root, context: stale_context,
        policy_path: File.join(ROOT, "policy", "security-lint.yml"),
        change_set: Object.new, validator: Object.new
      ).run

      assert_equal "expired", result.evidence.fetch("state")
      assert_equal 1, result.exit_status
    end
  end
end
