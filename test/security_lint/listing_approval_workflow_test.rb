# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"
require "yaml"

class SecurityLintListingApprovalWorkflowTest < Minitest::Test
  WORKFLOW = File.join(ROOT, ".github", "workflows", "listing-approval.yml")

  def test_dispatch_runs_only_trusted_code_with_confined_write_permissions
    workflow = File.read(WORKFLOW)
    YAML.safe_load(workflow, aliases: true)

    assert_includes workflow, "workflow_dispatch:"
    assert_includes workflow, "environment: honeycomb-listing-approval"
    assert_match(/contents: write/, workflow)
    assert_match(/actions: read/, workflow)
    assert_match(/pull-requests: read/, workflow)
    assert_match(/statuses: write/, workflow)
    assert_match(/issues: write/, workflow)
    refute_match(/^\s{2}pull_request:/, workflow)
    refute_includes workflow, "pull_request_target"
    refute_includes workflow, "secrets."
    assert_includes workflow, "persist-credentials: false"
    assert_includes workflow, "ruby script/honeycomb-listing-approval issue"
    assert_includes workflow, "options: [independent, repository_owner]"
    assert_includes workflow, HoneycombSecurityLint::ApprovalIssuer::OWNER_ACKNOWLEDGEMENT
    refute_match(/^\s*run:[^\n]*\$\{\{\s*(?:inputs|github\.event)/, workflow)
    uses = workflow.scan(/^\s*-?\s*uses:\s*([^\s]+)/).flatten
    refute_empty uses
    assert uses.all? { |value| value.match?(/\A[^@]+@[0-9a-f]{40}\z/) }, uses.inspect
  end
end
