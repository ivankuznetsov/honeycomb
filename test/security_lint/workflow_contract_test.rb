# frozen_string_literal: true

require_relative "../test_helper"

class SecurityLintWorkflowContractTest < Minitest::Test
  ANALYZER = File.join(ROOT, ".github", "workflows", "security-lint.yml")
  REPORTER = File.join(ROOT, ".github", "workflows", "security-lint-report.yml")

  def setup
    @analyzer = File.read(ANALYZER)
    @reporter = File.read(REPORTER)
  end

  def test_analyzer_is_pull_request_only_read_only_and_fork_safe
    assert_includes @analyzer, "pull_request:"
    refute_includes @analyzer, "pull_request_target"
    assert_match(/permissions:\n\s+contents: read/, @analyzer)
    refute_match(/permissions:\n(?:\s+.*\n)*?\s+contents: write/, @analyzer)
    refute_includes @analyzer, "secrets."
    refute_includes @analyzer, "self-hosted"
    refute_match(%r{actions/cache}, @analyzer)
    assert_includes @analyzer, "persist-credentials: false"
    assert_includes @analyzer, "github.event.pull_request.head.sha"
    assert_includes @analyzer, "safe-to-validate"
    assert_includes @analyzer, "cancel-in-progress: true"
  end

  def test_reporter_checks_out_only_default_branch_with_metadata_permissions
    assert_includes @reporter, "workflow_run:"
    assert_includes @reporter, "workflows: [\"Security lint\"]"
    %w[actions contents].each { |permission| assert_match(/#{permission}: read/, @reporter) }
    %w[pull-requests issues statuses].each { |permission| assert_match(/#{permission}: write/, @reporter) }
    refute_includes @reporter, "pull_request_target"
    refute_includes @reporter, "workflow_run.head_sha }}\n          persist-credentials"
    assert_includes @reporter, "github.event.repository.default_branch"
    assert_includes @reporter, "persist-credentials: false"
    refute_includes @reporter, "secrets."
  end

  def test_every_third_party_action_is_pinned_and_shell_does_not_interpolate_event_fields
    [@analyzer, @reporter].each do |workflow|
      uses = workflow.scan(/^\s*-?\s*uses:\s*([^\s]+)/).flatten
      refute_empty uses
      assert uses.all? { |value| value.match?(/\A[^@]+@[0-9a-f]{40}\z/) }, uses.inspect
    end
    refute_match(/^\s*run:[^\n]*\$\{\{\s*github\.event/, @reporter)
    refute_includes @reporter, "download-artifact"
  end
end
