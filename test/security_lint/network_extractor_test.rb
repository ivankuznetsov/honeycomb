# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintNetworkExtractorTest < Minitest::Test
  def command(raw)
    HoneycombSecurityLint::CommandExtractor::Command.new(
      path: "packages/example/1.0.0/README.md", line: 2, column: 1, kind: "fenced", raw: raw
    )
  end

  def test_normalizes_concrete_hosts_ports_and_dynamic_destinations
    observations = HoneycombSecurityLint::NetworkExtractor.new.extract([
      command("curl https://EXAMPLE.test:443/a"),
      command("wget http://example.test:8080/b"),
      command("curl $DOWNLOAD_URL")
    ])

    assert_equal ["<dynamic>", "example.test", "example.test:8080"], observations.map(&:host).sort
    assert observations.find { |entry| entry.host == "<dynamic>" }.dynamic
  end

  def test_userinfo_and_invalid_urls_become_untrusted_destinations
    observation = HoneycombSecurityLint::NetworkExtractor.new.extract([
      command("curl https://user:pass@example.test/file")
    ]).first

    assert observation.dynamic
    assert_equal "<invalid>", observation.host
  end
end
