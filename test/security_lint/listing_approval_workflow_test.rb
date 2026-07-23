# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"
require "yaml"

class SecurityLintListingApprovalWorkflowTest < Minitest::Test
  WORKFLOW = File.join(ROOT, ".github", "workflows", "listing-approval.yml")

  def test_dispatch_runs_only_trusted_code_with_confined_write_permissions
    workflow = File.read(WORKFLOW)
    document = YAML.safe_load(workflow, aliases: true)
    steps = document.fetch("jobs").fetch("issue").fetch("steps")
    checkout = steps.find { |step| step["name"] == "Check out trusted approval issuer" }
    approval = steps.find { |step| step["name"] == "Append exact-SHA listing evidence" }

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
    assert_equal false, checkout.dig("with", "persist-credentials")
    assert_equal "${{ github.event.repository.default_branch }}", checkout.dig("with", "ref")
    assert_includes approval.fetch("run"),
                    'DEFAULT_BRANCH_SHA="$(git -C "$GITHUB_WORKSPACE" rev-parse HEAD)"'
    assert_includes approval.fetch("run"), "ruby script/honeycomb-listing-approval issue"
    assert_equal "${{ github.token }}", approval.dig("env", "GITHUB_TOKEN")
    assert_includes workflow, "options: [independent, repository_owner]"
    assert_includes workflow, HoneycombSecurityLint::ApprovalIssuer::OWNER_ACKNOWLEDGEMENT
    assert_match(/review_id:\n(?:.*\n){0,4}\s+default: ""/, workflow)
    refute_match(/^\s*run:[^\n]*\$\{\{\s*(?:inputs|github\.event)/, workflow)
    uses = workflow.scan(/^\s*-?\s*uses:\s*([^\s]+)/).flatten
    refute_empty uses
    assert uses.all? { |value| value.match?(/\A[^@]+@[0-9a-f]{40}\z/) }, uses.inspect
  end
end
