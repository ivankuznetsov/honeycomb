# frozen_string_literal: true

require_relative "test_helper"
require "psych"

class CatalogPublicationWorkflowTest < Minitest::Test
  WORKFLOW = File.join(ROOT, ".github", "workflows", "catalog-check.yml")

  def test_catalog_gate_uses_protected_evidence_without_write_authority
    bytes = File.read(WORKFLOW)
    workflow = Psych.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
    triggers = workflow.fetch(true) # YAML 1.1 parses the unquoted GitHub key `on` as true.
    assert triggers.key?("pull_request")
    assert_equal ["main"], triggers.dig("push", "branches")
    assert triggers.key?("workflow_dispatch")
    assert_equal({"contents" => "read"}, workflow.fetch("permissions"))

    steps = workflow.dig("jobs", "check", "steps")
    source_checkout = steps.find { |step| step["name"] == "Check out registry source" }
    hive_checkout = steps.find { |step| step["name"] == "Check out compatible Hive source" }
    evidence_checkout = steps.find { |step| step["name"] == "Check out protected listing evidence" }
    source_contracts = steps.find { |step| step["name"] == "Verify source contracts" }
    catalog_check = steps.find do |step|
      step["name"] == "Verify canonical catalog against protected evidence"
    end

    assert_equal false, source_checkout.dig("with", "persist-credentials")
    assert_equal 0, source_checkout.dig("with", "fetch-depth")
    assert_equal "ivankuznetsov/hive", hive_checkout.dig("with", "repository")
    assert_match(/\A[0-9a-f]{40}\z/, hive_checkout.dig("with", "ref"))
    assert_equal false, hive_checkout.dig("with", "persist-credentials")
    assert_equal "honeycomb-evidence", evidence_checkout.dig("with", "ref")
    assert_equal false, evidence_checkout.dig("with", "persist-credentials")
    assert_equal "ruby test/run.rb", source_contracts.fetch("run")
    assert_equal "${{ github.workspace }}/hive/lib", source_contracts.dig("env", "RUBYLIB")
    assert_includes catalog_check.fetch("run"), "ruby script/honeycomb-catalog --check"
    assert_includes catalog_check.fetch("run"), "normalized/listing-evidence-v1.json"
    refute_includes bytes, "contents: write"
    refute_includes bytes, "secrets."

    uses = steps.filter_map { |step| step["uses"] }
    refute_empty uses
    assert uses.all? { |value| value.match?(/\A[^@]+@[0-9a-f]{40}\z/) }, uses.inspect
  end
end
