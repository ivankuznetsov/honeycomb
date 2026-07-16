# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintPermissionCheckerTest < Minitest::Test
  def setup
    @policy = HoneycombSecurityLint::Policy.load(File.join(ROOT, "policy", "security-lint.yml"))
    @checker = HoneycombSecurityLint::PermissionChecker.new(policy: @policy)
  end

  def command(raw)
    HoneycombSecurityLint::CommandExtractor::Command.new(
      path: "packages/example/1.0.0/instructions/a.md", line: 1, column: 1, kind: "fenced", raw: raw
    )
  end

  def permissions(overrides = {})
    {
      "risk" => "low", "capabilities" => ["filesystem-read", "shell"],
      "network_hosts" => [], "filesystem_read" => ["repository"],
      "filesystem_write" => [], "secrets" => []
    }.merge(overrides)
  end

  def test_blocks_observed_undeclared_shell_network_write_paths_and_secrets
    commands = [command("curl $API_URL"), command("rm /tmp/file"), command("echo $DEPLOY_TOKEN")]
    observations = HoneycombSecurityLint::NetworkExtractor.new.extract(commands)
    findings, = @checker.check(
      commands: commands, observations: observations,
      permissions: permissions("capabilities" => []),
      security_extension: {"network_host_reasons" => {}, "suppressions" => []}
    )
    rule_ids = findings.map { |finding| finding["rule_id"] }

    assert_includes rule_ids, "permission.shell"
    assert_includes rule_ids, "permission.network"
    assert_includes rule_ids, "permission.filesystem-write"
    assert_includes rule_ids, "permission.absolute-path"
    assert_includes rule_ids, "permission.secret"
    assert_includes rule_ids, "network.dynamic-destination"
  end

  def test_exact_declared_host_with_reason_is_advisory_evidence
    commands = [command("curl https://api.example.test/data")]
    observations = HoneycombSecurityLint::NetworkExtractor.new.extract(commands)
    findings, hosts = @checker.check(
      commands: commands, observations: observations,
      permissions: permissions("capabilities" => ["network", "shell"], "network_hosts" => ["api.example.test"]),
      security_extension: {"network_host_reasons" => {"api.example.test" => "Public metadata"}, "suppressions" => []}
    )

    refute findings.any? { |finding| finding["disposition"] == "hard" }
    assert_equal "advisory", hosts.first.fetch("disposition")
    assert_equal "Public metadata", hosts.first.fetch("reason")
  end

  def test_host_mismatch_missing_reason_ip_and_broad_permissions_fail_or_remain_visible
    cases = [
      ["curl https://other.example.test", ["api.example.test"], "network.undeclared-host"],
      ["curl https://api.example.test", ["api.example.test"], "network.missing-reason"],
      ["curl https://127.0.0.1", ["127.0.0.1"], "network.ip-literal"]
    ]
    cases.each do |raw, hosts, expected|
      commands = [command(raw)]
      findings, = @checker.check(
        commands: commands, observations: HoneycombSecurityLint::NetworkExtractor.new.extract(commands),
        permissions: permissions("capabilities" => ["network", "shell"], "network_hosts" => hosts),
        security_extension: {"network_host_reasons" => {}, "suppressions" => []}
      )
      assert_includes findings.map { |finding| finding["rule_id"] }, expected
    end

    findings, = @checker.check(
      commands: [], observations: [],
      permissions: permissions("risk" => "high", "filesystem_read" => ["*"]),
      security_extension: {"network_host_reasons" => {}, "suppressions" => []}
    )
    assert_equal "advisory", findings.first.fetch("disposition")
  end
end
