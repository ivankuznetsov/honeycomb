# frozen_string_literal: true

require "json"
require "time"

module HoneycombSecurityLint
  class ApprovalIssuer
    ELIGIBLE_PERMISSIONS = %w[admin maintain write].freeze
    AUTHORITIES = %w[independent repository_owner].freeze
    OWNER_ACKNOWLEDGEMENT = "I accept first-party publication responsibility".freeze
    DECISIONS = {"approved" => "APPROVED", "denied" => "CHANGES_REQUESTED"}.freeze
    INPUT_KEYS = %w[
      pull_request head_sha lint_run_id name version release_sha256 evidence_digest
      review_id decision notes approved_suppressions publication_authority owner_acknowledgement
    ].freeze
    OPTIONAL_INPUT_DEFAULTS = {"review_id" => "", "owner_acknowledgement" => ""}.freeze

    class Invalid < StandardError; end

    def initialize(event:, client:, store:, repository:, artifact_loader: nil, root: nil,
                   approval_run_id: nil)
      @event = event
      @client = client
      @store = store
      @repository = repository
      @approval_run_id = approval_run_id
      @renderer = Renderer.new(max_items: root ? policy_limits(root).fetch("max_rendered_items") : 50)
      @artifact_loader = artifact_loader || begin
        raise Invalid, "trusted repository root is required" unless root
        policy = Policy.load(File.join(File.expand_path(root), "policy", "security-lint.yml"))
        EvidenceArtifact.new(client: client, policy: policy).method(:load)
      end
    end

    def issue
      inputs, reviewer = validate_event
      pull_number = positive_integer(inputs.fetch("pull_request"), "pull request")
      run_id = positive_integer(inputs.fetch("lint_run_id"), "lint run ID")
      authority = inputs.fetch("publication_authority")
      raise Invalid, "publication authority is invalid" unless AUTHORITIES.include?(authority)
      validate_sha!(inputs.fetch("head_sha"), "head SHA")
      validate_sha256!(inputs.fetch("release_sha256"), "release fingerprint")
      validate_sha256!(inputs.fetch("evidence_digest"), "evidence digest")

      pull = @client.pull(pull_number)
      validate_reviewer!(reviewer, pull, authority)
      validate_pull!(pull, inputs.fetch("head_sha"))
      validate_protected_paths!(pull_number, pull)
      status = validate_status!(inputs.fetch("head_sha"), run_id)

      evidence = @artifact_loader.call(run_id)
      package = validate_evidence!(evidence, inputs, pull_number, run_id)
      suppressions = parse_suppressions(inputs.fetch("approved_suppressions"), package)
      if inputs.fetch("decision") == "denied" && !suppressions.empty?
        raise Invalid, "a denied review cannot approve suppressions"
      end
      review = approval_audit!(
        pull_number, reviewer, inputs, authority, suppressions
      )

      approval = {
        "name" => package.dig("identity", "name"),
        "version" => package.dig("identity", "version"),
        "path" => package.dig("identity", "path"),
        "release_sha256" => package.dig("identity", "release_sha256"),
        "head_sha" => evidence.fetch("head_sha"),
        "reviewer" => reviewer,
        "authority" => authority,
        "decision" => inputs.fetch("decision"),
        "reviewed_at" => review.fetch("submitted_at"),
        "evidence_digest" => evidence.fetch("artifact_digest"),
        "review_url" => review.fetch("html_url"),
        "notes" => inputs.fetch("notes"),
        "approved_suppressions" => suppressions
      }
      Contracts.validate_approvals({"schema" => Contracts::APPROVAL_SCHEMA, "approvals" => [approval]})
      final_evidence = finalize_evidence!(evidence, package, approval, status)
      @store.append_approval(approval)
      @store.append_lint(final_evidence)
      publish_finalized!(pull_number, run_id, final_evidence) if final_evidence["artifact_digest"] != evidence["artifact_digest"]
      approval
    rescue KeyError, JSON::ParserError, Contracts::Invalid, EvidenceArtifact::Invalid,
           ArtifactArchive::Invalid, GitHubClient::Error => e
      raise Invalid, Redactor.sanitize_text(e.message)
    end

    private

    def validate_event
      unless @event.dig("repository", "full_name") == @repository
        raise Invalid, "workflow dispatch repository is invalid"
      end
      inputs = @event["inputs"]
      unless inputs.is_a?(Hash)
        raise Invalid, "workflow dispatch inputs are incomplete"
      end
      inputs = OPTIONAL_INPUT_DEFAULTS.merge(inputs)
      raise Invalid, "workflow dispatch inputs are incomplete" unless (INPUT_KEYS - inputs.keys).empty?
      reviewer = @event.dig("sender", "login")
      unless reviewer.is_a?(String) && EvidenceStore::LOGIN_PATTERN.match?(reviewer)
        raise Invalid, "workflow dispatch sender is invalid"
      end
      [inputs, reviewer]
    end

    def validate_reviewer!(reviewer, pull, authority)
      permission = @client.collaborator_permission(reviewer)
      raise Invalid, "reviewer is not an eligible maintainer" unless ELIGIBLE_PERMISSIONS.include?(permission)

      if authority == "independent" && pull.dig("user", "login").to_s.casecmp?(reviewer)
        raise Invalid, "a pull-request submitter cannot approve their own submission"
      end
      return if authority == "independent"

      owner = @repository.split("/", 2).first
      unless permission == "admin" && owner.casecmp?(reviewer) &&
             pull.dig("user", "login").to_s.casecmp?(reviewer) &&
             pull.dig("head", "repo", "full_name") == @repository
        raise Invalid, "repository-owner publication requires the admin owner, their own pull request, and the canonical repository"
      end
    end

    def validate_pull!(pull, head_sha)
      unless pull.is_a?(Hash) && pull["state"] == "open" && pull.dig("head", "sha") == head_sha
        raise Invalid, "pull request is closed or its head SHA is stale"
      end
    end

    def validate_protected_paths!(pull_number, pull)
      if @client.pull_files(pull_number, expected_count: pull.fetch("changed_files")).any? do |path|
           Reporter::PROTECTED_PATH.match?(path.to_s)
         end
        raise Invalid, "trusted security tooling must be reviewed in a separate pull request"
      end
    end

    def validate_status!(head_sha, run_id)
      status = @client.commit_statuses(head_sha).find do |entry|
        entry["context"] == Reporter::STATUS_CONTEXT
      end
      expected_url = "https://github.com/#{@repository}/actions/runs/#{run_id}"
      unless status && %w[success failure].include?(status["state"]) && status["target_url"] == expected_url
        raise Invalid, "authoritative security lint status is not current or terminal"
      end
      status
    end

    def validate_review!(pull_number, review_id, reviewer, decision, head_sha)
      expected_state = DECISIONS[decision]
      raise Invalid, "listing decision is invalid" unless expected_state
      review = @client.pull_review(pull_number, review_id)
      unless review["id"] == review_id && review.dig("user", "login").to_s.casecmp?(reviewer) &&
             review["state"] == expected_state && review["commit_id"] == head_sha
        raise Invalid, "pull-request review is missing, dismissed, stale, or inconsistent"
      end
      decisive = @client.pull_reviews(pull_number).select do |entry|
        entry.dig("user", "login").to_s.casecmp?(reviewer) &&
          %w[APPROVED CHANGES_REQUESTED DISMISSED].include?(entry["state"]) &&
          entry["submitted_at"].is_a?(String)
      end
      ranked = decisive.map do |entry|
        [entry, Time.iso8601(entry.fetch("submitted_at")), Integer(entry.fetch("id"))]
      end
      latest = ranked.max_by { |_entry, submitted_at, id| [submitted_at, id] }&.first
      unless latest && latest["id"] == review_id
        raise Invalid, "pull-request review is not the reviewer's latest decisive review"
      end
      review
    rescue ArgumentError, TypeError
      raise Invalid, "pull-request review history is malformed"
    end

    def approval_audit!(pull_number, reviewer, inputs, authority, suppressions)
      if authority == "independent"
        unless inputs.fetch("owner_acknowledgement").to_s.empty?
          raise Invalid, "independent review cannot include repository-owner acknowledgement"
        end
        review_id = positive_integer(inputs.fetch("review_id"), "review ID")
        return validate_review!(
          pull_number, review_id, reviewer, inputs.fetch("decision"), inputs.fetch("head_sha")
        )
      end

      unless inputs.fetch("review_id").to_s.empty? &&
             inputs.fetch("decision") == "approved" &&
             inputs.fetch("owner_acknowledgement") == OWNER_ACKNOWLEDGEMENT &&
             !inputs.fetch("notes").to_s.strip.empty? && suppressions.empty?
        raise Invalid, "repository-owner publication requires an approval acknowledgement, audit notes, and no suppressions"
      end
      validate_owner_audit!(reviewer)
    end

    def validate_owner_audit!(reviewer)
      run_id = positive_integer(@approval_run_id, "approval workflow run ID")
      run = @client.workflow_run(run_id)
      expected_url = "https://github.com/#{@repository}/actions/runs/#{run_id}"
      unless run.is_a?(Hash) && run["id"] == run_id && run["event"] == "workflow_dispatch" &&
             run["path"] == ".github/workflows/listing-approval.yml" &&
             run.dig("repository", "full_name") == @repository &&
             run.dig("actor", "login").to_s.casecmp?(reviewer) &&
             run["html_url"] == expected_url
        raise Invalid, "repository-owner publication workflow audit is invalid"
      end
      submitted_at = Time.iso8601(run.fetch("created_at")).utc.iso8601
      {"submitted_at" => submitted_at, "html_url" => run.fetch("html_url")}
    rescue ArgumentError, TypeError
      raise Invalid, "repository-owner publication audit timestamp is invalid"
    end

    def validate_evidence!(evidence, inputs, pull_number, run_id)
      Contracts.validate_evidence(evidence)
      raise Invalid, "security lint evidence digest is invalid" unless Contracts.artifact_digest_valid?(evidence)
      expected = [pull_number, inputs.fetch("head_sha"), run_id, @repository]
      actual = [
        evidence["pull_request"], evidence["head_sha"], evidence.dig("run", "id"),
        evidence.dig("run", "repository")
      ]
      unless actual == expected && %w[pass fail].include?(evidence["state"])
        raise Invalid, "security lint evidence identity is stale or not terminal"
      end
      unless evidence.dig("event", "gate") == "applied" && evidence.dig("event", "label_sha") == evidence["head_sha"]
        raise Invalid, "security lint evidence does not have a current maintainer gate"
      end
      unless evidence["artifact_digest"] == inputs.fetch("evidence_digest")
        raise Invalid, "security lint evidence digest does not match the dispatch"
      end

      package = evidence.fetch("packages").find do |entry|
        identity = entry.fetch("identity")
        identity.values_at("name", "version", "release_sha256") ==
          inputs.values_at("name", "version", "release_sha256")
      end
      raise Invalid, "honeycomb identity does not match security lint evidence" unless package
      package
    end

    def finalize_evidence!(evidence, package, approval, status)
      if approval["decision"] == "denied"
        return evidence
      end
      if approval["approved_suppressions"].empty?
        unless status["state"] == "success" && evidence["state"] == "pass" && package["verdict"] == "pass"
          raise Invalid, "honeycomb lint result is not passing"
        end
        return evidence
      end

      final = Evidence.apply_approvals(evidence, [approval])
      final_package = final.fetch("packages").find do |entry|
        entry.dig("identity", "path") == approval["path"]
      end
      unless final["state"] == "pass" && final_package && final_package["verdict"] == "pass"
        raise Invalid, "approved suppressions do not produce passing security lint evidence"
      end
      final
    end

    def publish_finalized!(pull_number, run_id, evidence)
      head_sha = evidence.fetch("head_sha")
      return unless @client.pull(pull_number).dig("head", "sha") == head_sha

      target_url = "https://github.com/#{@repository}/actions/runs/#{run_id}"
      @client.create_status(
        head_sha,
        {
          "state" => "success", "context" => Reporter::STATUS_CONTEXT,
          "description" => "Security lint passed after exact maintainer suppressions",
          "target_url" => target_url
        }
      )
      return unless @client.pull(pull_number).dig("head", "sha") == head_sha

      body = @renderer.comment(evidence)
      owned = @client.comments(pull_number).find do |comment|
        comment.dig("user", "login") == Reporter::BOT_LOGIN &&
          comment["body"].to_s.include?(Renderer::COMMENT_MARKER)
      end
      if owned
        @client.update_comment(owned.fetch("id"), body)
      else
        @client.create_comment(pull_number, body)
      end
    end

    def policy_limits(root)
      Policy.load(File.join(File.expand_path(root), "policy", "security-lint.yml")).limits
    end

    def parse_suppressions(source, package)
      values = JSON.parse(source)
      unless values.is_a?(Array) && values.uniq.length == values.length &&
             values.all? { |value| value.is_a?(String) && Contracts::SHA256_PATTERN.match?(value) }
        raise Invalid, "approved suppressions must be a JSON array of exact fingerprints"
      end
      requested = package.fetch("suppressions").map { |entry| entry.fetch("fingerprint") }
      unless (values - requested).empty?
        raise Invalid, "approved suppression is not requested by current evidence"
      end
      values.sort
    end

    def positive_integer(value, label)
      integer = Integer(value, 10)
      raise Invalid, "#{label} must be positive" unless integer.positive?
      integer
    rescue ArgumentError, TypeError
      raise Invalid, "#{label} must be a positive integer"
    end

    def validate_sha!(value, label)
      raise Invalid, "#{label} is invalid" unless value.is_a?(String) && Contracts::SHA_PATTERN.match?(value)
    end

    def validate_sha256!(value, label)
      raise Invalid, "#{label} is invalid" unless value.is_a?(String) && Contracts::SHA256_PATTERN.match?(value)
    end
  end
end
