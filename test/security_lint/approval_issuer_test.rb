# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintApprovalIssuerTest < Minitest::Test
  SHA = "d" * 40
  RELEASE = "a" * 64

  class FakeClient
    attr_accessor :permission, :pull_data, :files, :statuses, :review

    def initialize
      @permission = "maintain"
      @pull_data = {
        "state" => "open", "user" => {"login" => "author"},
        "head" => {"sha" => SHA}
      }
      @files = ["packages/example/1.0.0/README.md"]
      @statuses = [{
        "context" => HoneycombSecurityLint::Reporter::STATUS_CONTEXT,
        "state" => "success",
        "target_url" => "https://github.com/hive-sh/honeycomb/actions/runs/7"
      }]
      @review = {
        "id" => 99, "state" => "APPROVED", "user" => {"login" => "maintainer"},
        "submitted_at" => "2026-07-17T10:00:00Z",
        "html_url" => "https://github.com/hive-sh/honeycomb/pull/42#pullrequestreview-99"
      }
    end

    def collaborator_permission(_login) = permission
    def pull(_number) = pull_data
    def pull_files(_number) = files
    def commit_statuses(_sha) = statuses
    def pull_review(_number, _review_id) = review
  end

  class FakeStore
    attr_reader :lint_records, :approval_records

    def initialize
      @lint_records = []
      @approval_records = []
    end

    def append_lint(evidence) = lint_records << evidence
    def append_approval(record) = approval_records << record
  end

  def evidence
    HoneycombSecurityLint::Evidence.finalize({
      "schema" => "honeycomb.security-lint/v1",
      "event" => {"action" => "labeled", "gate" => "applied", "label_sha" => SHA},
      "pull_request" => 42, "base_sha" => "c" * 40, "head_sha" => SHA,
      "run" => {
        "id" => 7, "attempt" => 1, "workflow" => "Security lint",
        "repository" => "hive-sh/honeycomb"
      },
      "artifact_digest" => nil, "state" => "pass",
      "packages" => [{
        "identity" => {
          "name" => "example", "version" => "1.0.0",
          "path" => "packages/example/1.0.0", "release_sha256" => RELEASE
        },
        "validator_findings" => [], "requested_permissions" => {"risk" => "low"},
        "scanned_files" => [], "commands" => [], "hosts" => [], "findings" => [],
        "suppressions" => [], "counts" => {"hard" => 0, "advisory" => 0, "downgraded" => 0},
        "verdict" => "pass"
      }],
      "totals" => {"hard" => 0, "advisory" => 0, "downgraded" => 0},
      "verdict" => "Security lint passed"
    })
  end

  def event(record = evidence)
    {
      "repository" => {"full_name" => "hive-sh/honeycomb", "default_branch" => "main"},
      "sender" => {"login" => "maintainer"},
      "inputs" => {
        "pull_request" => "42", "head_sha" => SHA, "lint_run_id" => "7",
        "name" => "example", "version" => "1.0.0", "release_sha256" => RELEASE,
        "evidence_digest" => record.fetch("artifact_digest"), "review_id" => "99",
        "decision" => "approved", "notes" => "Reviewed the complete honeycomb diff",
        "approved_suppressions" => "[]"
      }
    }
  end

  def issuer(client: FakeClient.new, store: FakeStore.new, record: evidence, event_data: nil)
    event_data ||= event(record)
    HoneycombSecurityLint::ApprovalIssuer.new(
      event: event_data, client: client, store: store,
      repository: "hive-sh/honeycomb", artifact_loader: ->(_run_id) { record }
    )
  end

  def test_issues_current_sha_bound_approval_and_persists_lint_first
    store = FakeStore.new

    approval = issuer(store: store).issue

    assert_equal "maintainer", approval.fetch("reviewer")
    assert_equal SHA, approval.fetch("head_sha")
    assert_equal RELEASE, approval.fetch("release_sha256")
    assert_equal evidence.fetch("artifact_digest"), approval.fetch("evidence_digest")
    assert_equal [evidence], store.lint_records
    assert_equal [approval], store.approval_records
  end

  def test_rejects_ineligible_self_stale_failed_or_dismissed_reviews
    mutations = [
      ->(client, _event) { client.permission = "read" },
      ->(client, _event) { client.pull_data["user"]["login"] = "maintainer" },
      ->(client, _event) { client.pull_data["head"]["sha"] = "e" * 40 },
      ->(client, _event) { client.statuses[0]["state"] = "failure" },
      ->(client, _event) { client.review["state"] = "DISMISSED" },
      ->(client, input) { input["inputs"]["evidence_digest"] = "f" * 64 }
    ]

    mutations.each do |mutation|
      client = FakeClient.new
      input = event
      mutation.call(client, input)
      assert_raises(HoneycombSecurityLint::ApprovalIssuer::Invalid) do
        issuer(client: client, event_data: input).issue
      end
    end
  end

  def test_rejects_protected_tooling_and_suppression_not_present_in_evidence
    client = FakeClient.new
    client.files << "script/honeycomb-listing-approval"
    assert_raises(HoneycombSecurityLint::ApprovalIssuer::Invalid) { issuer(client: client).issue }

    input = event
    input["inputs"]["approved_suppressions"] = JSON.generate(["f" * 64])
    assert_raises(HoneycombSecurityLint::ApprovalIssuer::Invalid) do
      issuer(event_data: input).issue
    end
  end
end
