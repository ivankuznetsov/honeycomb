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
    candidate_hive_checkout = steps.find do |step|
      step["name"] == "Check out Root Cause Repair candidate Hive source"
    end
    evidence_checkout = steps.find { |step| step["name"] == "Check out protected listing evidence" }
    source_contracts = steps.find { |step| step["name"] == "Verify source contracts" }
    candidate_contracts = steps.find do |step|
      step["name"] == "Verify Root Cause Repair candidate against patched Hive"
    end
    catalog_check = steps.find do |step|
      step["name"] == "Verify canonical catalog against protected evidence"
    end

    assert_equal false, source_checkout.dig("with", "persist-credentials")
    assert_equal 0, source_checkout.dig("with", "fetch-depth")
    assert_equal "ivankuznetsov/hive", hive_checkout.dig("with", "repository")
    assert_equal "af22485f9b2bee27a7497dc138e5e58ab9725bde", hive_checkout.dig("with", "ref")
    assert_equal false, hive_checkout.dig("with", "persist-credentials")
    assert_equal "ivankuznetsov/hive", candidate_hive_checkout.dig("with", "repository")
    assert_equal "83ac363cb761a41345798ca05ad5f704c60b9795",
                 candidate_hive_checkout.dig("with", "ref")
    assert_equal false, candidate_hive_checkout.dig("with", "persist-credentials")
    assert_equal "honeycomb-evidence", evidence_checkout.dig("with", "ref")
    assert_equal false, evidence_checkout.dig("with", "persist-credentials")
    assert_equal "ruby test/run.rb", source_contracts.fetch("run")
    assert_equal "${{ github.workspace }}/hive", source_contracts.dig("env", "HONEYCOMB_HIVE_SOURCE")
    assert_equal "${{ github.workspace }}/hive/lib", source_contracts.dig("env", "RUBYLIB")
    assert_equal "ruby -Itest test/root_cause_repair_candidate_hive_execution_test.rb",
                 candidate_contracts.fetch("run")
    assert_equal "${{ github.workspace }}/hive-root-cause-candidate",
                 candidate_contracts.dig("env", "HONEYCOMB_HIVE_SOURCE")
    assert_equal "${{ github.workspace }}/hive-root-cause-candidate/lib",
                 candidate_contracts.dig("env", "RUBYLIB")
    assert_includes catalog_check.fetch("run"), "ruby script/honeycomb-catalog --check"
    assert_includes catalog_check.fetch("run"), "normalized/listing-evidence-v1.json"
    refute_includes bytes, "contents: write"
    refute_includes bytes, "secrets."

    uses = steps.filter_map { |step| step["uses"] }
    refute_empty uses
    assert uses.all? { |value| value.match?(/\A[^@]+@[0-9a-f]{40}\z/) }, uses.inspect
  end
end
