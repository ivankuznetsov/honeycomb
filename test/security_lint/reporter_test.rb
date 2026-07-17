# frozen_string_literal: true

require_relative "../test_helper"
require "digest"
require "zlib"
require "honeycomb_security_lint"

class SecurityLintReporterTest < Minitest::Test
  SHA = "d" * 40
  BASE = "c" * 40

  class FakeClient
    attr_accessor :pull_data, :files, :comment_data, :artifact_data, :archive, :run_data, :comment_error
    attr_reader :created_comments, :updated_comments, :statuses, :removed_labels

    def initialize
      @pull_data = {"head" => {"sha" => SHA}, "base" => {"sha" => BASE}, "changed_files" => 1}
      @files = ["packages/example/1.0.0/README.md"]
      @comment_data = []
      @created_comments = []
      @updated_comments = []
      @statuses = []
      @removed_labels = []
      @run_data = [{
        "run_number" => 3, "run_attempt" => 1, "display_title" => "Security lint / labeled / safe-to-validate",
        "pull_requests" => [{"number" => 42}]
      }]
    end

    def pull(_number) = pull_data
    def pull_files(_number, expected_count:)
      raise HoneycombSecurityLint::GitHubClient::Error, "incomplete" unless expected_count == files.length
      files
    end
    def workflow_runs(_workflow, head_sha:) = run_data
    def artifacts(_run_id) = artifact_data
    def download_artifact(_url) = archive
    def comments(_number)
      raise HoneycombSecurityLint::GitHubClient::Error, "comments unavailable" if comment_error
      comment_data
    end
    def create_comment(number, body) = created_comments << [number, body]
    def update_comment(id, body) = updated_comments << [id, body]
    def create_status(sha, attributes) = statuses << [sha, attributes]
    def remove_label(number, label) = removed_labels << [number, label]
  end

  def event
    {
      "action" => "completed", "repository" => {"full_name" => "hive-sh/honeycomb"},
      "workflow_run" => {
        "id" => 7, "run_attempt" => 1, "run_number" => 3, "name" => "Security lint",
        "event" => "pull_request", "path" => ".github/workflows/security-lint.yml",
        "head_sha" => SHA, "html_url" => "https://github.com/hive-sh/honeycomb/actions/runs/7",
        "pull_requests" => [{"number" => 42}]
      }
    }
  end

  def evidence(state: "pass", action: "labeled", gate: "applied")
    HoneycombSecurityLint::Evidence.finalize(
      {
        "schema" => "honeycomb.security-lint/v1",
        "event" => {"action" => action, "gate" => gate, "label_sha" => action == "labeled" ? SHA : nil},
        "pull_request" => 42, "base_sha" => BASE, "head_sha" => SHA,
        "run" => {"id" => 7, "attempt" => 1, "workflow" => "Security lint", "repository" => "hive-sh/honeycomb"},
        "artifact_digest" => nil, "state" => state, "packages" => [],
        "totals" => {"hard" => 0, "advisory" => 0, "downgraded" => 0},
        "verdict" => HoneycombSecurityLint::Evidence::VERDICTS.fetch(state)
      }
    )
  end

  def zip(bytes, name: "evidence.json")
    crc = Zlib.crc32(bytes)
    local = [0x04034b50, 20, 0, 0, 0, 0, crc, bytes.bytesize, bytes.bytesize, name.bytesize, 0]
            .pack("VvvvvvVVVvv") + name + bytes
    central = [0x02014b50, 0x0314, 20, 0, 0, 0, 0, crc, bytes.bytesize, bytes.bytesize,
               name.bytesize, 0, 0, 0, 0, 0o100644 << 16, 0]
              .pack("VvvvvvvVVVvvvvvVV") + name
    eocd = [0x06054b50, 0, 0, 1, 1, central.bytesize, local.bytesize, 0].pack("VvvvvVVv")
    local + central + eocd
  end

  def client_for(record = evidence, name: "evidence.json")
    client = FakeClient.new
    archive = zip(HoneycombSecurityLint::Contracts.canonical_json(record), name: name)
    client.archive = archive
    client.artifact_data = [{
      "name" => "security-lint-evidence", "expired" => false, "size_in_bytes" => archive.bytesize,
      "digest" => "sha256:#{Digest::SHA256.hexdigest(archive)}",
      "archive_download_url" => "https://api.github.test/artifacts/1/zip"
    }]
    client
  end

  def reporter(client, event_data: event)
    HoneycombSecurityLint::Reporter.new(
      root: ROOT, event: event_data, client: client,
      repository: "hive-sh/honeycomb"
    )
  end

  def test_valid_current_artifact_creates_or_updates_one_owned_comment_and_success_status
    client = client_for
    assert_equal :reported, reporter(client).report
    assert_equal 1, client.created_comments.length
    assert_empty client.updated_comments
    assert_equal SHA, client.statuses.first.first
    assert_equal "success", client.statuses.first.last.fetch("state")
    assert_includes client.created_comments.first.last, HoneycombSecurityLint::Renderer::COMMENT_MARKER

    client = client_for
    client.comment_data = [
      {"id" => 9, "body" => "#{HoneycombSecurityLint::Renderer::COMMENT_MARKER}\nold", "user" => {"login" => "github-actions[bot]"}}
    ]
    assert_equal :reported, reporter(client).report
    assert_empty client.created_comments
    assert_equal 9, client.updated_comments.first.first
  end

  def test_matching_marker_from_another_author_is_not_hijacked
    client = client_for
    client.comment_data = [
      {"id" => 9, "body" => HoneycombSecurityLint::Renderer::COMMENT_MARKER, "user" => {"login" => "attacker"}}
    ]

    reporter(client).report

    assert_empty client.updated_comments
    assert_equal 1, client.created_comments.length
  end

  def test_stale_run_is_a_no_op_before_artifact_or_writes
    client = client_for
    client.pull_data = {"head" => {"sha" => "e" * 40}, "base" => {"sha" => BASE}, "changed_files" => 1}

    assert_equal :stale, reporter(client).report
    assert_empty client.created_comments
    assert_empty client.statuses
  end

  def test_missing_malformed_traversing_or_digest_mismatched_artifacts_fail_current_head_closed
    clients = []
    missing = client_for
    missing.artifact_data = []
    clients << missing
    clients << client_for(evidence, name: "../evidence.json")
    malformed = client_for
    malformed.archive = zip("not json")
    malformed.artifact_data[0]["size_in_bytes"] = malformed.archive.bytesize
    malformed.artifact_data[0]["digest"] = "sha256:#{Digest::SHA256.hexdigest(malformed.archive)}"
    clients << malformed
    digest_mismatch = client_for
    digest_mismatch.artifact_data[0]["digest"] = "sha256:#{"0" * 64}"
    clients << digest_mismatch
    duplicate = client_for
    duplicate.artifact_data << duplicate.artifact_data.first.dup
    clients << duplicate
    oversized = client_for
    oversized.artifact_data[0]["size_in_bytes"] = 10_000_000
    clients << oversized
    identity_mismatch = client_for
    mismatched = evidence
    mismatched["run"]["attempt"] = 2
    clients << client_for(HoneycombSecurityLint::Evidence.finalize(mismatched))

    clients.each do |client|
      assert_equal :failed_closed, reporter(client).report
      assert_equal "error", client.statuses.first.last.fetch("state")
      assert_includes client.created_comments.first.last, "could not be trusted"
      refute_includes client.created_comments.first.last, "not json"
    end
  end

  def test_protected_tooling_change_refuses_artifact_pass_with_split_guidance
    client = client_for
    client.files << "lib/honeycomb_security_lint/rule_engine.rb"
    client.pull_data["changed_files"] = 2

    assert_equal :reported, reporter(client).report
    assert_equal "failure", client.statuses.first.last.fetch("state")
    assert_includes client.created_comments.first.last, "separate pull request"
  end


  def test_incomplete_file_list_fails_closed
    client = client_for
    client.pull_data["changed_files"] = 2

    assert_equal :failed_closed, reporter(client).report
    assert_equal "error", client.statuses.first.last.fetch("state")
  end

  def test_non_package_pull_publishes_unchanged_required_status
    client = client_for
    client.files = ["docs/PACKAGE_FORMAT.md"]

    assert_equal :unchanged, reporter(client).report
    assert_equal "success", client.statuses.first.last.fetch("state")
    assert_includes client.created_comments.first.last, "No changed honeycomb"
  end

  def test_newer_same_head_run_supersedes_older_report
    client = client_for
    client.run_data << {
      "run_number" => 4, "run_attempt" => 1, "display_title" => "Security lint / synchronize / none",
      "pull_requests" => [{"number" => 42}]
    }

    assert_equal :superseded, reporter(client).report
    assert_empty client.statuses
    assert_empty client.created_comments
  end


  def test_unrelated_label_run_does_not_supersede_authoritative_result
    client = client_for
    client.run_data << {
      "run_number" => 4, "run_attempt" => 1, "display_title" => "Security lint / labeled / documentation",
      "pull_requests" => [{"number" => 42}]
    }

    assert_equal :reported, reporter(client).report
    assert_equal "success", client.statuses.first.last.fetch("state")
  end

  def test_newer_attempt_of_same_run_supersedes_older_report
    client = client_for
    client.run_data << {
      "run_number" => 3, "run_attempt" => 2, "display_title" => "Security lint / labeled / safe-to-validate",
      "pull_requests" => [{"number" => 42}]
    }

    assert_equal :superseded, reporter(client).report
    assert_empty client.statuses
  end

  def test_comment_failure_does_not_suppress_authoritative_status
    client = client_for
    client.comment_error = true

    assert_equal :reported, reporter(client).report
    assert_equal "success", client.statuses.first.last.fetch("state")
  end

  def test_spdx_policy_change_is_protected
    client = client_for
    client.files << "policy/spdx-license-ids.txt"
    client.pull_data["changed_files"] = 2

    assert_equal :reported, reporter(client).report
    assert_equal "failure", client.statuses.first.last.fetch("state")
  end

  def test_synchronize_pending_state_removes_gate_only_for_current_head
    record = evidence(state: "expired", action: "synchronize", gate: "expired")
    client = client_for(record)

    assert_equal :reported, reporter(client).report
    assert_equal "pending", client.statuses.first.last.fetch("state")
    assert_equal [[42, "safe-to-validate"]], client.removed_labels
  end
end
