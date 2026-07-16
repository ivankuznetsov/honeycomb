# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintRedactorTest < Minitest::Test
  def test_sanitizes_workflow_commands_controls_and_length
    value = "::error::bad\0" + "x" * 600
    sanitized = HoneycombSecurityLint::Redactor.sanitize_text(value, max_bytes: 40)

    refute_match(/\A::/, sanitized)
    assert_includes sanitized, "\\::error\\::"
    refute_includes sanitized, "\0"
    assert_operator sanitized.bytesize, :<=, 43
  end

  def test_redacts_secrets_in_arbitrary_text
    secret = "ghp_" + "A" * 24
    redacted = HoneycombSecurityLint::SecretPiiScanner.new.redact_text("use #{secret} now")

    refute_includes redacted, secret
    assert_includes redacted, "redacted secret.github-token"
  end
end
