# frozen_string_literal: true

module HoneycombSecurityLint
  class EvidenceStore
    BRANCH = "honeycomb-evidence"
    LOGIN_PATTERN = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z/

    class Invalid < StandardError; end
    class Conflict < StandardError; end

    def initialize(client:, base_branch:, branch: BRANCH)
      raise Invalid, "evidence branch is fixed" unless branch == BRANCH
      unless base_branch.is_a?(String) && base_branch.match?(/\A[A-Za-z0-9._\/-]+\z/) &&
             !base_branch.include?("..") && !base_branch.start_with?("/")
        raise Invalid, "default branch is invalid"
      end

      @client = client
      @base_branch = base_branch
      @branch = branch
      @ensured = false
    end

    def append_lint(evidence)
      record = Contracts.plain_copy(evidence)
      Contracts.validate_evidence(record)
      raise Invalid, "lint evidence content digest is invalid" unless Contracts.artifact_digest_valid?(record)

      path = "lint/#{record.fetch("head_sha")}/#{record.fetch("artifact_digest")}.json"
      append(path, Contracts.canonical_json(record), "Record security lint evidence")
    rescue Contracts::Invalid => e
      raise Invalid, e.message
    end

    def append_approval(approval)
      record = Contracts.plain_copy(approval)
      document = {"schema" => Contracts::APPROVAL_SCHEMA, "approvals" => [record]}
      Contracts.validate_approvals(document)
      reviewer = record.fetch("reviewer")
      unless LOGIN_PATTERN.match?(reviewer) && reviewer.length <= 39
        raise Invalid, "reviewer login is invalid"
      end

      path = [
        "approvals", record.fetch("name"), record.fetch("version"),
        record.fetch("head_sha"), "#{reviewer.downcase}.json"
      ].join("/")
      append(path, Contracts.canonical_json(document), "Record honeycomb listing approval")
    rescue Contracts::Invalid => e
      raise Invalid, e.message
    end

    private

    def append(path, bytes, message)
      ensure_branch
      @client.create_content(path, bytes: bytes, branch: @branch, message: message)
      :created
    rescue GitHubClient::Conflict
      existing = @client.content(path, ref: @branch)
      return :unchanged if existing == bytes

      raise Conflict, "immutable evidence record already exists with different content"
    end

    def ensure_branch
      return if @ensured

      @client.ensure_branch(@branch, base_branch: @base_branch)
      @ensured = true
    end
  end
end
