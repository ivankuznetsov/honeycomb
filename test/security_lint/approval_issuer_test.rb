# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintApprovalIssuerTest < Minitest::Test
  SHA = "d" * 40
  RELEASE = "a" * 64
  OWNER_ACKNOWLEDGEMENT = HoneycombSecurityLint::ApprovalIssuer::OWNER_ACKNOWLEDGEMENT

  class FakeClient
    attr_accessor :permission, :pull_data, :files, :statuses, :review, :reviews, :comment_data,
                  :workflow_run_data
    attr_reader :created_statuses, :created_comments, :updated_comments

    def initialize
      @permission = "maintain"
      @pull_data = {
        "state" => "open", "user" => {"login" => "author"},
        "head" => {"sha" => SHA, "repo" => {"full_name" => "hive-sh/honeycomb"}},
        "changed_files" => 1
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
      @workflow_run_data = {
        "id" => 88,
        "event" => "workflow_dispatch",
        "path" => ".github/workflows/listing-approval.yml",
        "repository" => {"full_name" => "hive-sh/honeycomb"},
        "actor" => {"login" => "hive-sh"},
        "created_at" => "2026-07-19T06:00:00Z",
        "html_url" => "https://github.com/hive-sh/honeycomb/actions/runs/88"
      }
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
    def workflow_run(_run_id) = workflow_run_data
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
        "publication_authority" => "independent", "owner_acknowledgement" => "",
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

  def owner_client
    FakeClient.new.tap do |client|
      client.permission = "admin"
      client.pull_data["user"]["login"] = "hive-sh"
    end
  end

  def owner_event(record = evidence)
    event(record).tap do |input|
      input["sender"]["login"] = "hive-sh"
      input["inputs"].merge!(
        "review_id" => "",
        "publication_authority" => "repository_owner",
        "owner_acknowledgement" => OWNER_ACKNOWLEDGEMENT,
        "notes" => "First-party release accepted by the repository owner"
      )
    end
  end

  def owner_issuer(client: owner_client, event_data: owner_event, approval_run_id: "88")
    HoneycombSecurityLint::ApprovalIssuer.new(
      event: event_data, client: client, store: FakeStore.new,
      repository: "hive-sh/honeycomb", artifact_loader: ->(_run_id) { evidence },
      approval_run_id: approval_run_id
    )
  end

  def evidence_with_requested_suppression
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
    [HoneycombSecurityLint::Evidence.finalize(record), fingerprint]
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

  def test_repository_owner_can_publish_first_party_release_without_a_second_collaborator
    client = owner_client
    input = owner_event
    store = FakeStore.new

    approval = HoneycombSecurityLint::ApprovalIssuer.new(
      event: input, client: client, store: store, repository: "hive-sh/honeycomb",
      artifact_loader: ->(_run_id) { evidence },
      approval_run_id: "88"
    ).issue

    assert_equal "repository_owner", approval.fetch("authority")
    assert_equal "hive-sh", approval.fetch("reviewer")
    assert_equal "2026-07-19T06:00:00Z", approval.fetch("reviewed_at")
    assert_equal "https://github.com/hive-sh/honeycomb/actions/runs/88", approval.fetch("review_url")
    assert_equal [approval], store.approval_records
  end

  def test_repository_owner_publication_rejects_non_owner_fork_ambiguity_and_incomplete_acknowledgement
    mutations = [
      ->(client, _input) { client.permission = "maintain" },
      ->(_client, input) { input["sender"]["login"] = "other-admin" },
      ->(client, _input) { client.pull_data["user"]["login"] = "other-author" },
      ->(client, _input) { client.pull_data["head"]["repo"]["full_name"] = "hive-sh/fork" },
      ->(_client, input) { input["inputs"]["owner_acknowledgement"] = "yes" },
      ->(_client, input) { input["inputs"]["decision"] = "denied" },
      ->(_client, input) { input["inputs"]["review_id"] = "99" },
      ->(_client, input) { input["inputs"]["notes"] = "  " }
    ]

    mutations.each do |mutation|
      client = owner_client
      input = owner_event
      mutation.call(client, input)
      assert_raises(HoneycombSecurityLint::ApprovalIssuer::Invalid) do
        owner_issuer(client: client, event_data: input).issue
      end
    end

    workflow_run_mutations = [
      ->(run) { run["id"] = 89 },
      ->(run) { run["event"] = "push" },
      ->(run) { run["path"] = ".github/workflows/other.yml" },
      ->(run) { run["repository"]["full_name"] = "hive-sh/other" },
      ->(run) { run["actor"]["login"] = "other-admin" },
      ->(run) { run["html_url"] = "https://example.test/actions/runs/88" },
      ->(run) { run["created_at"] = "not-a-timestamp" }
    ]
    workflow_run_mutations.each do |mutation|
      client = owner_client
      mutation.call(client.workflow_run_data)
      assert_raises(HoneycombSecurityLint::ApprovalIssuer::Invalid) do
        owner_issuer(client: client).issue
      end
    end
  end

  def test_repository_owner_publication_is_idempotent_for_a_workflow_run
    first = owner_issuer.issue
    second = owner_issuer.issue

    assert_equal first, second
  end

  def test_repository_owner_publication_cannot_approve_requested_suppressions
    record, fingerprint = evidence_with_requested_suppression
    client = owner_client
    client.statuses.first["state"] = "failure"
    input = owner_event(record)
    input["inputs"]["approved_suppressions"] = JSON.generate([fingerprint])
    store = FakeStore.new
    issuer = HoneycombSecurityLint::ApprovalIssuer.new(
      event: input, client: client, store: store, repository: "hive-sh/honeycomb",
      artifact_loader: ->(_run_id) { record },
      approval_run_id: "88"
    )

    assert_raises(HoneycombSecurityLint::ApprovalIssuer::Invalid) { issuer.issue }
    assert_empty store.approval_records
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
    record, fingerprint = evidence_with_requested_suppression
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
