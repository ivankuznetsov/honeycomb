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

  def test_literal_url_does_not_mask_dynamic_destination_but_header_values_are_not_destinations
    mixed = HoneycombSecurityLint::NetworkExtractor.new.extract([
      command("curl -H $HEADER https://example.test/ping $DEST")
    ])

    assert_equal ["<dynamic>", "example.test"], mixed.map(&:host).sort

    header_only = HoneycombSecurityLint::NetworkExtractor.new.extract([
      command("curl -H $HEADER https://example.test/ping")
    ])
    assert_equal ["example.test"], header_only.map(&:host)
  end

  def test_observation_budget_fails_closed
    assert_raises(HoneycombSecurityLint::NetworkExtractor::LimitExceeded) do
      HoneycombSecurityLint::NetworkExtractor.new(max_observations: 1).extract([
        command("curl https://one.example.test https://two.example.test")
      ])
    end
  end

  def test_single_command_budget_is_checked_before_materializing_every_observation
    extractor_class = Class.new(HoneycombSecurityLint::NetworkExtractor) do
      attr_reader :materialized

      def initialize(**arguments)
        super
        @materialized = 0
      end

      private

      def observation(*arguments)
        @materialized += 1
        super
      end
    end
    extractor = extractor_class.new(max_observations: 1)

    error = assert_raises(HoneycombSecurityLint::NetworkExtractor::LimitExceeded) do
      extractor.extract([command("curl https://one.example.test https://two.example.test")])
    end
    assert_equal "network observation count exceeds policy", error.message
    assert_equal 1, extractor.materialized
  end

  def test_curl_remote_name_flag_does_not_consume_dynamic_destination
    observations = HoneycombSecurityLint::NetworkExtractor.new.extract([
      command("curl https://github.com/archive.zip -O $DEST")
    ])

    assert_equal ["<dynamic>", "github.com"], observations.map(&:host).sort
  end

  def test_option_arity_is_scoped_to_the_network_client
    observations = HoneycombSecurityLint::NetworkExtractor.new.extract([
      command("wget https://github.com/archive.zip -H $DEST")
    ])

    assert_equal ["<dynamic>", "github.com"], observations.map(&:host).sort
  end

  def test_attached_curl_url_is_a_destination
    observations = HoneycombSecurityLint::NetworkExtractor.new.extract([
      command("curl https://github.com/archive.zip --url=$DEST")
    ])

    assert_equal ["<dynamic>", "github.com"], observations.map(&:host).sort
  end
end
