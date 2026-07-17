# frozen_string_literal: true

module HoneycombSecurityLint
  class Reporter
    ARTIFACT_NAME = EvidenceArtifact::ARTIFACT_NAME
    STATUS_CONTEXT = "honeycomb/security-lint"
    BOT_LOGIN = "github-actions[bot]"
    PROTECTED_PATH = %r{\A(?:
      \.github/workflows/|
      lib/honeycomb_security_lint(?:\.rb|/)|
      lib/honeycomb_registry(?:\.rb|/)|
      script/honeycomb-(?:security-lint(?:-report)?|listing-approval|validate|manifest|catalog)\z|
      policy/|
      schemas/[^/]+\.json\z
    )}x
    STATE_MAP = {
      "pass" => ["success", "Security lint passed"],
      "fail" => ["failure", "Security lint found blocking evidence"],
      "awaiting_maintainer" => ["pending", "Awaiting safe-to-validate on this head"],
      "expired" => ["pending", "Evidence expired; reapply safe-to-validate"],
      "unchanged" => ["success", "No changed honeycomb versions"],
      "error" => ["error", "Security lint failed closed"]
    }.freeze

    class Invalid < StandardError; end

    def initialize(root:, event:, client:, repository:)
      @root = File.expand_path(root)
      @event = event
      @client = client
      @repository = repository
      @policy = Policy.load(File.join(@root, "policy", "security-lint.yml"))
      @renderer = Renderer.new(max_items: @policy.limits.fetch("max_rendered_items"))
      @artifact_loader = EvidenceArtifact.new(client: client, policy: @policy)
    end

    def report
      run, pull_number = validate_workflow_event
      pull = @client.pull(pull_number)
      return :stale unless current_pull?(pull, run.fetch("head_sha"))

      begin
        files = @client.pull_files(pull_number, expected_count: pull.fetch("changed_files"))
        evidence = load_evidence(run)
        validate_evidence_identity(evidence, run, pull_number, pull)
      rescue KeyError, EvidenceArtifact::Invalid, ArtifactArchive::Invalid, Contracts::Invalid, GitHubClient::Error, Invalid
        publish_fail_closed(pull_number, run)
        return :failed_closed
      end

      return :unchanged if unrelated_label_evidence?(evidence)
      return :superseded unless latest_source_run?(pull_number, run)
      return report_unrelated_pull(pull_number, run) unless files.any? { |path| path.start_with?("packages/") }

      protected_change = files.any? { |path| PROTECTED_PATH.match?(path) }
      state, body = report_view(evidence, protected_change)
      publish_status(pull_number, run, state)
      publish_comment_safely(pull_number, run, body)
      remove_expired_label(pull_number, run, evidence)
      :reported
    end

    private

    def validate_workflow_event
      raise Invalid, "workflow_run action is invalid" unless @event["action"] == "completed"
      raise Invalid, "workflow_run repository is invalid" unless @event.dig("repository", "full_name") == @repository
      run = @event["workflow_run"]
      raise Invalid, "workflow_run metadata is missing" unless run.is_a?(Hash)
      valid_path = run["path"].to_s.split("@", 2).first == ".github/workflows/security-lint.yml"
      valid_name = run["name"] == "Security lint" || run["name"].to_s.start_with?("Security lint / ")
      unless valid_name && run["event"] == "pull_request" && valid_path
        raise Invalid, "workflow_run identity is invalid"
      end
      unless run["id"].is_a?(Integer) && run["id"].positive? &&
             run["run_attempt"].is_a?(Integer) && run["run_attempt"].positive? &&
             run["run_number"].is_a?(Integer) && run["run_number"].positive? &&
             run["head_sha"].is_a?(String) && Contracts::SHA_PATTERN.match?(run["head_sha"])
        raise Invalid, "workflow_run run identity is invalid"
      end
      pulls = run["pull_requests"]
      unless pulls.is_a?(Array) && pulls.length == 1 && pulls.first["number"].is_a?(Integer) && pulls.first["number"].positive?
        raise Invalid, "workflow_run must identify exactly one pull request"
      end
      [run, pulls.first.fetch("number")]
    end

    def load_evidence(run)
      @artifact_loader.load(run.fetch("id"))
    end

    def validate_evidence_identity(evidence, run, pull_number, pull)
      expected_run = [run["id"], run["run_attempt"], "Security lint", @repository]
      actual_run = evidence.fetch("run").values_at("id", "attempt", "workflow", "repository")
      raise Invalid, "evidence workflow identity mismatch" unless actual_run == expected_run
      raise Invalid, "evidence pull request mismatch" unless evidence["pull_request"] == pull_number
      raise Invalid, "evidence head SHA mismatch" unless evidence["head_sha"] == run["head_sha"]
      raise Invalid, "evidence base SHA is stale" unless evidence["base_sha"] == pull.dig("base", "sha")
      validate_event_state(evidence)
    end

    def validate_event_state(evidence)
      action = evidence.dig("event", "action")
      gate = evidence.dig("event", "gate")
      state = evidence["state"]
      valid = case action
              when "opened"
                gate == "required" && state == "awaiting_maintainer"
              when "synchronize", "reopened"
                gate == "expired" && state == "expired"
              when "labeled"
                (gate == "applied" && %w[pass fail error unchanged].include?(state) && evidence.dig("event", "label_sha") == evidence["head_sha"]) ||
                  (gate == "unchanged" && state == "unchanged")
              else
                false
              end
      raise Invalid, "evidence event state is inconsistent" unless valid
    end

    def unrelated_label_evidence?(evidence)
      evidence.dig("event", "action") == "labeled" && evidence.dig("event", "gate") == "unchanged"
    end

    def report_view(evidence, protected_change)
      if protected_change
        rendered = Contracts.plain_copy(evidence)
        rendered["state"] = "fail"
        rendered["verdict"] = "Security lint cannot pass while trusted tooling changes; move tooling changes to a separate pull request"
        ["failure", @renderer.comment(rendered)]
      else
        [STATE_MAP.fetch(evidence.fetch("state")).first, @renderer.comment(evidence)]
      end
    end

    def publish_fail_closed(pull_number, run)
      return unless current_source_run?(pull_number, run)
      body = <<~MARKDOWN
        #{Renderer::COMMENT_MARKER}
        ## Honeycomb security lint

        Security lint evidence for this head could not be trusted. The authoritative status is fail-closed; re-run validation or inspect the reporter workflow.
      MARKDOWN
      publish_status(pull_number, run, "error")
      publish_comment_safely(pull_number, run, body)
    end

    def report_unrelated_pull(pull_number, run)
      body = <<~MARKDOWN
        #{Renderer::COMMENT_MARKER}
        ## Honeycomb security lint

        No changed honeycomb versions were found in this pull request.
      MARKDOWN
      publish_status(pull_number, run, "success")
      publish_comment_safely(pull_number, run, body)
      :unchanged
    end

    def publish_comment(pull_number, run, body)
      return false unless current_source_run?(pull_number, run)
      owned = @client.comments(pull_number).find do |comment|
        comment.dig("user", "login") == BOT_LOGIN && comment["body"].to_s.include?(Renderer::COMMENT_MARKER)
      end
      return false unless current_source_run?(pull_number, run)
      if owned
        @client.update_comment(owned.fetch("id"), body)
      else
        @client.create_comment(pull_number, body)
      end
      true
    end

    def publish_comment_safely(pull_number, run, body)
      publish_comment(pull_number, run, body)
    rescue GitHubClient::Error
      false
    end

    def publish_status(pull_number, run, state)
      return false unless current_source_run?(pull_number, run)
      mapped_state, description = state == "error" ? STATE_MAP.fetch("error") : [state, status_description(state)]
      @client.create_status(
        run.fetch("head_sha"),
        {
          "state" => mapped_state, "context" => STATUS_CONTEXT,
          "description" => description, "target_url" => run.fetch("html_url")
        }
      )
      true
    end

    def status_description(state)
      STATE_MAP.values.find { |entry| entry.first == state }&.last || "Security lint reported #{state}"
    end

    def remove_expired_label(pull_number, run, evidence)
      return unless %w[synchronize reopened].include?(evidence.dig("event", "action"))
      return unless current_source_run?(pull_number, run)
      @client.remove_label(pull_number, "safe-to-validate")
    end

    def current_pull?(pull, head_sha)
      pull.is_a?(Hash) && pull.dig("head", "sha") == head_sha
    end

    def current_head?(pull_number, head_sha)
      current_pull?(@client.pull(pull_number), head_sha)
    end

    def current_source_run?(pull_number, run)
      current_head?(pull_number, run.fetch("head_sha")) && latest_source_run?(pull_number, run)
    end

    def latest_source_run?(pull_number, run)
      @client.workflow_runs("security-lint.yml", head_sha: run.fetch("head_sha")).none? do |candidate|
        authoritative_source_run?(candidate) && newer_source_run?(candidate, run) &&
          Array(candidate["pull_requests"]).any? { |pull| pull["number"] == pull_number }
      end
    end

    def authoritative_source_run?(run)
      title = run["display_title"].to_s
      !title.start_with?("Security lint / labeled / ") ||
        title == "Security lint / labeled / safe-to-validate"
    end

    def newer_source_run?(candidate, current)
      candidate_identity = [candidate["run_number"], candidate["run_attempt"]]
      current_identity = [current.fetch("run_number"), current.fetch("run_attempt")]
      candidate_identity.all? { |value| value.is_a?(Integer) } &&
        (candidate_identity <=> current_identity) == 1
    end
  end
end
