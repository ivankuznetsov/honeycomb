# frozen_string_literal: true

require_relative "test_helper"
require "psych"

class SubmissionCanaryWorkflowTest < Minitest::Test
  WORKFLOW = File.join(ROOT, ".github", "workflows", "submission-canary.yml")

  def test_canary_is_fixed_bot_authored_and_uses_two_commit_provenance
    bytes = File.read(WORKFLOW)
    workflow = Psych.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
    triggers = workflow.fetch(true) # YAML 1.1 parses the unquoted GitHub key `on` as true.

    assert_equal ["version"], triggers.fetch("workflow_dispatch").fetch("inputs").keys
    assert_equal({"contents" => "write", "pull-requests" => "write"}, workflow.fetch("permissions"))

    steps = workflow.dig("jobs", "submit", "steps")
    checkout = steps.find { |step| step["name"] == "Check out trusted registry source" }
    submit = steps.find { |step| step["name"] == "Open a bot-authored task-inspect submission" }
    script = submit.fetch("run")

    assert_match(%r{actions/checkout@[0-9a-f]{40}\z}, checkout.fetch("uses"))
    assert_equal 0, checkout.dig("with", "fetch-depth")
    assert_includes script, 'PACKAGE_DIR="packages/task-inspect/$VERSION"'
    assert_includes script, 'git config user.name "github-actions[bot]"'
    assert_includes script, 'git commit -m "feat(task-inspect): add $VERSION source"'
    assert_includes script, 'SOURCE_SHA=$(git rev-parse HEAD)'
    assert_includes script, 'git commit -m "chore(task-inspect): finalize $VERSION manifest"'
    assert_includes script, "hive_min_version: 0.5.2"
    assert_includes script, "preset: scoped"
    assert_includes script, "gh pr create"
    refute_includes script, "gh pr review"
  end
end

