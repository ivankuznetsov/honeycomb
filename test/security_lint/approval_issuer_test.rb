# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintApprovalIssuerTest < Minitest::Test
  SHA = "d" * 40
  RELEASE = "a" * 64

  class FakeClient
    attr_accessor :permission, :pull_data, :files, :statuses, :review, :reviews, :comment_data
    attr_reader :created_statuses, :created_comments, :updated_comments

    def initialize
      @permission = "maintain"
      @pull_data = {
        "state" => "open", "user" => {"login" => "author"},
        "head" => {"sha" => SHA}, "changed_files" => 1
      }
      @files = ["packages/example/1.0.0/README.md"]
      @statuses = [{
        "context" => HoneycombSecurityLint::Reporter::STATUS_CONTEXT,
        "state" => "success",
        "target_url" => "https://github.com/hive-sh/honeycomb/actions/runs/7"
      }]
      @review = {
        "id" => 99, "state" => "APPROVED", "user" => {"login" => "maintainer"},
        "commit_id" => SHA,
        "submitted_at" => "2026-07-17T10:00:00Z",
        "html_url" => "https://github.com/hive-sh/honeycomb/pull/42#pullrequestreview-99"
      }
      @reviews = [@review]
      @comment_data = []
      @created_statuses = []
      @created_comments = []
      @updated_comments = []
    end

    def collaborator_permission(_login) = permission
    def pull(_number) = pull_data
    def pull_files(_number, expected_count:)
      raise HoneycombSecurityLint::GitHubClient::Error, "incomplete" unless expected_count == files.length
      files
    end
    def commit_statuses(_sha) = statuses
    def pull_review(_number, _review_id) = review
    def pull_reviews(_number) = reviews
    def create_status(sha, attributes) = created_statuses << [sha, attributes]
    def comments(_number) = comment_data
    def create_comment(number, body) = created_comments << [number, body]
    def update_comment(id, body) = updated_comments << [id, body]
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
      ->(client, _event) { client.review["commit_id"] = "e" * 40 },
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


  def test_rejects_superseded_review_and_inexact_status_identity
    client = FakeClient.new
    client.reviews << client.review.merge(
      "id" => 100, "state" => "CHANGES_REQUESTED", "submitted_at" => "2026-07-17T11:00:00Z"
    )
    assert_raises(HoneycombSecurityLint::ApprovalIssuer::Invalid) { issuer(client: client).issue }

    [
      ->(entry) { entry["target_url"] = "https://github.com/hive-sh/honeycomb/actions/runs/8" },
      ->(entry) { entry["context"] = "other/status" }
    ].each do |mutation|
      client = FakeClient.new
      mutation.call(client.statuses.first)
      assert_raises(HoneycombSecurityLint::ApprovalIssuer::Invalid) { issuer(client: client).issue }
    end
  end

  def test_exact_suppression_finalizes_evidence_and_publishes_success
    fingerprint = "f" * 64
    record = evidence
    package = record.fetch("packages").first
    package["findings"] = [{
      "rule_id" => "secret.fixture", "category" => "secret", "original_severity" => "hard",
      "disposition" => "hard", "path" => "packages/example/1.0.0/README.md", "line" => 1,
      "column" => 1, "fingerprint" => fingerprint, "redacted_evidence" => "[redacted]",
      "message" => "Fixture secret", "request" => {"reason" => "Inert fixture"}, "approval" => nil
    }]
    package["suppressions"] = [{
      "fingerprint" => fingerprint, "reason" => "Inert fixture", "status" => "requested", "approval" => nil
    }]
    record = HoneycombSecurityLint::Evidence.finalize(record)
    input = event(record)
    input["inputs"]["approved_suppressions"] = JSON.generate([fingerprint])
    client = FakeClient.new
    client.statuses.first["state"] = "failure"
    store = FakeStore.new

    approval = issuer(client: client, store: store, record: record, event_data: input).issue

    assert_equal [fingerprint], approval.fetch("approved_suppressions")
    assert_equal "pass", store.lint_records.first.fetch("state")
    assert_equal "success", client.created_statuses.first.last.fetch("state")
    assert_equal 1, client.created_comments.length
  end

  def test_rejects_protected_tooling_and_suppression_not_present_in_evidence
    client = FakeClient.new
    client.files << "script/honeycomb-listing-approval"
    client.pull_data["changed_files"] = 2
    assert_raises(HoneycombSecurityLint::ApprovalIssuer::Invalid) { issuer(client: client).issue }

    input = event
    input["inputs"]["approved_suppressions"] = JSON.generate(["f" * 64])
    assert_raises(HoneycombSecurityLint::ApprovalIssuer::Invalid) do
      issuer(event_data: input).issue
    end
  end
end
