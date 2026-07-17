# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintSecretPiiScannerTest < Minitest::Test
  def source(text, path: "packages/example/1.0.0/README.md")
    HoneycombSecurityLint::TextFiles::Source.new(
      path: path, absolute_path: "/unread", bytes: text, text: text, sha256: Digest::SHA256.hexdigest(text)
    )
  end

  def test_detects_provider_tokens_private_keys_and_generic_credentials_without_leaking_values
    secrets = [
      "ghp_" + "A" * 24,
      "sk-proj-" + "Ab9_" * 8,
      "sk-ant-" + "aB9-" * 8,
      "AKIA" + "A1" * 8,
      "xoxb-" + "1-aB" * 5,
      "AIza" + "A1_" * 10,
      "eyJ" + "A" * 10 + "." + "B" * 10 + "." + "C" * 10,
      "-----BEGIN PRIVATE KEY-----",
      "api_key='A1b2C3d4E5f6G7h8I9j0K1l2'"
    ]
    text = secrets.join("\n")
    findings = HoneycombSecurityLint::SecretPiiScanner.new.scan([source(text)])
    serialized = JSON.generate(findings)

    assert findings.length >= secrets.length
    assert findings.all? { |finding| finding["disposition"] == "hard" }
    secrets.each { |secret| refute_includes serialized, secret }
    assert findings.all? { |finding| finding["fingerprint"].match?(/\A[0-9a-f]{64}\z/) }
  end

  def test_blocks_valid_card_and_labeled_government_id_but_keeps_email_advisory
    text = "card: 4111 1111 1111 1111\nSSN: 123-45-6789\ncontact person@example.test\n"
    findings = HoneycombSecurityLint::SecretPiiScanner.new.scan([source(text)])
    by_rule = findings.to_h { |finding| [finding["rule_id"], finding] }

    assert_equal "hard", by_rule.fetch("pii.payment-card").fetch("disposition")
    assert_equal "hard", by_rule.fetch("pii.government-id").fetch("disposition")
    assert_equal "advisory", by_rule.fetch("pii.email").fetch("disposition")
    refute_includes JSON.generate(findings), "4111"
    refute_includes JSON.generate(findings), "123-45"
  end

  def test_ordinary_numbers_and_low_entropy_placeholders_do_not_block
    text = "issue 123456789012 and api_key='aaaaaaaaaaaaaaaaaaaa'\n"
    findings = HoneycombSecurityLint::SecretPiiScanner.new.scan([source(text)])

    refute findings.any? { |finding| finding["disposition"] == "hard" }
  end

  def test_fingerprint_changes_with_content_or_location
    scanner = HoneycombSecurityLint::SecretPiiScanner.new
    first = scanner.scan([source("SSN: 123-45-6789\n")]).first
    changed_content = scanner.scan([source("SSN: 987-65-4321\n")]).first
    changed_path = scanner.scan([source("SSN: 123-45-6789\n", path: "packages/example/1.0.0/instructions/a.md")]).first

    refute_equal first["fingerprint"], changed_content["fingerprint"]
    refute_equal first["fingerprint"], changed_path["fingerprint"]
  end

  def test_finding_budget_stops_dense_input
    scanner = HoneycombSecurityLint::SecretPiiScanner.new(max_findings: 2)
    text = "person@example.test\n" * 3

    assert_raises(HoneycombSecurityLint::SecretPiiScanner::LimitExceeded) do
      scanner.scan([source(text)])
    end
  end
end
