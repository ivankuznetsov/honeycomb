# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintPolicyTest < Minitest::Test
  def setup
    @policy = HoneycombSecurityLint::Policy.load(File.join(ROOT, "policy", "security-lint.yml"))
  end

  def manifest
    {
      "permissions" => {"network_hosts" => ["api.example.test"]},
      "x-security" => {
        "network_host_reasons" => {"api.example.test" => "Fetches public release metadata"},
        "suppressions" => [{"fingerprint" => "a" * 64, "reason" => "Documented fixture placeholder"}]
      }
    }
  end

  def test_accepts_reasons_for_authoritative_hosts_and_exact_requests
    result = @policy.security_extension(manifest)

    assert_equal "Fetches public release metadata", result.dig("network_host_reasons", "api.example.test")
    assert_equal "a" * 64, result.fetch("suppressions").first.fetch("fingerprint")
  end

  def test_extension_cannot_grant_hosts_or_use_broad_suppressions
    extra = manifest
    extra["x-security"]["network_host_reasons"]["undeclared.example.test"] = "please"
    assert_raises(HoneycombSecurityLint::Contracts::Invalid) { @policy.security_extension(extra) }

    broad = manifest
    broad["x-security"]["suppressions"][0]["fingerprint"] = "secret.*"
    assert_raises(HoneycombSecurityLint::Contracts::Invalid) { @policy.security_extension(broad) }
  end
end
