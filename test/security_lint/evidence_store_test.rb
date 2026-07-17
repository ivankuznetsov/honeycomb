# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintEvidenceStoreTest < Minitest::Test
  class FakeClient
    attr_reader :branches, :files, :writes

    def initialize
      @branches = []
      @files = {}
      @writes = []
    end

    def ensure_branch(branch, base_branch:)
      branches << [branch, base_branch]
    end

    def create_content(path, bytes:, branch:, message:)
      raise HoneycombSecurityLint::GitHubClient::Conflict, "exists" if files.key?([branch, path])

      files[[branch, path]] = bytes
      writes << [path, bytes, branch, message]
    end

    def content(path, ref:)
      files.fetch([ref, path])
    end
  end

  def approval(reviewer: "Maintainer")
    {
      "name" => "example", "version" => "1.0.0", "path" => "packages/example/1.0.0",
      "release_sha256" => "a" * 64, "head_sha" => "d" * 40, "reviewer" => reviewer,
      "decision" => "approved", "reviewed_at" => "2026-07-17T10:00:00Z",
      "evidence_digest" => "b" * 64,
      "review_url" => "https://github.com/hive-sh/honeycomb/pull/42#pullrequestreview-99",
      "notes" => "reviewed", "approved_suppressions" => []
    }
  end

  def test_append_is_immutable_and_idempotent_for_identical_canonical_bytes
    client = FakeClient.new
    store = HoneycombSecurityLint::EvidenceStore.new(client: client, base_branch: "main")

    first = store.append_approval(approval)
    replay = store.append_approval(approval)

    assert_equal :created, first
    assert_equal :unchanged, replay
    assert_equal [[HoneycombSecurityLint::EvidenceStore::BRANCH, "main"]], client.branches.uniq
    assert_equal 1, client.writes.length
    assert_match(%r{\Aapprovals/example/1\.0\.0/#{"d" * 40}/maintainer-[0-9a-f]{64}\.json\z}, client.writes.first.first)
  end


  def test_renewed_review_uses_a_distinct_immutable_record
    client = FakeClient.new
    store = HoneycombSecurityLint::EvidenceStore.new(client: client, base_branch: "main")
    store.append_approval(approval)
    renewed = approval.merge(
      "decision" => "denied", "reviewed_at" => "2026-07-17T11:00:00Z",
      "review_url" => "https://github.com/hive-sh/honeycomb/pull/42#pullrequestreview-100"
    )

    assert_equal :created, store.append_approval(renewed)
    assert_equal 2, client.writes.length
    refute_equal client.writes[0].first, client.writes[1].first
  end

  def test_conflicting_reviewer_record_fails_closed
    client = FakeClient.new
    store = HoneycombSecurityLint::EvidenceStore.new(client: client, base_branch: "main")
    store.append_approval(approval)
    changed = approval.merge("decision" => "denied")

    assert_raises(HoneycombSecurityLint::EvidenceStore::Conflict) do
      store.append_approval(changed)
    end
  end
end
