# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "honeycomb_security_lint"
require "psych"

class RootCauseRepairPackageTest < Minitest::Test
  PACKAGE_ROOT = File.join(ROOT, "candidates", "root-cause-repair", "1.0.0")
  IDENTITY_KEYS = %w[agent model effort].freeze
  PROHIBITED_OPERATIONS = %w[
    reset clean stash revert commit push PR merge tag release publish deploy
  ].freeze
  SEMANTIC_SLOTS = %w[
    stages.reproduce
    stages.diagnose
    stages.repair
    stages.verification
    stages.verification.reviewers.causal-verifier
    stages.verification.revise
    stages.certificate
  ].freeze
  BEHAVIOR_PATHS = %w[
    workflow.yml
    instructions/reproduce.md
    instructions/diagnose.md
    instructions/repair.md
    instructions/verify.md
    instructions/revise-repair.md
    instructions/certificate.md
    assets/evidence-contract.md
    tools/repository-state.rb
  ].freeze

  def test_workflow_has_the_exact_repair_and_verification_topology
    workflow = load_workflow

    assert_equal "root-cause-repair", workflow.fetch("id")
    assert_equal %w[inbox reproduce diagnose repair verification certificate], stage_names(workflow)
    assert_stage("inbox", kind: "terminal", state_file: "brief.md")
    assert_stage("reproduce", kind: "agent", state_file: "reproduce.md", instruction: "instructions/reproduce.md")
    assert_stage("diagnose", kind: "agent", state_file: "diagnose.md", instruction: "instructions/diagnose.md")
    assert_stage("repair", kind: "agent", state_file: "repair.md", instruction: "instructions/repair.md")

    verification = stage("verification")
    assert_equal "council", verification.fetch("kind")
    assert_equal "verification.md", verification.fetch("state_file")
    assert_equal "repair.md", verification.fetch("input")
    assert_equal 1, verification.dig("council", "quorum")
    assert_equal 3, verification.dig("council", "max_rounds")
    assert_equal "consensus", verification.dig("council", "exit_rule")
    assert_equal "complete", verification.dig("council", "on_max_rounds")
    assert_equal "instructions/revise-repair.md", verification.dig("council", "revise", "instruction")
    assert_equal ["causal-verifier"], verification.fetch("reviewers").map { |reviewer| reviewer.fetch("name") }
    assert_equal "instructions/verify.md", verification.fetch("reviewers").first.fetch("instruction")

    assert_stage("certificate", kind: "agent", state_file: "repair-certificate.md",
                 instruction: "instructions/certificate.md", deliverable: "repair-certificate.md")
  end

  def test_every_executable_actor_is_unique_agent_agnostic_and_unbounded
    expected_roles = {
      "stages.reproduce" => "development",
      "stages.diagnose" => "development",
      "stages.repair" => "development",
      "stages.verification" => "reviewer",
      "stages.verification.reviewers.causal-verifier" => "reviewer",
      "stages.verification.revise" => "development",
      "stages.certificate" => "reviewer"
    }

    actors = executable_slots(load_workflow)
    assert_equal expected_roles.keys, actors.keys
    assert_empty recursive_keys(load_workflow) & IDENTITY_KEYS
    assert_equal actors.length, actors.values.map { |actor| actor.fetch("mapping_contract") }.uniq.length

    actors.each do |slot_id, actor|
      assert_equal expected_roles.fetch(slot_id), actor.fetch("mapping_role"), slot_id
      assert_match HoneycombRegistry::HiveCompatibility::MAPPING_CONTRACT_PATTERN,
                   actor.fetch("mapping_contract"), slot_id
      assert_equal "yolo", actor.fetch("permissions"), slot_id
      assert_empty actor.keys & IDENTITY_KEYS, slot_id
    end
  end

  def test_prompts_separate_workflow_status_reviewer_verdict_and_terminal_outcome
    intermediate = %w[reproduce diagnose repair revise-repair].to_h do |name|
      [name, instruction(name)]
    end
    intermediate.each do |name, prompt|
      assert_includes prompt, "Workflow-Status:", name
      refute_match(/^Outcome:/, prompt, name)
    end

    reviewer = instruction("verify")
    assert_includes reviewer, "Verdict: ready|changes_requested"
    refute_match(/^Outcome:/, reviewer)

    certificate = instruction("certificate")
    assert_includes certificate, "Outcome: verified|not-reproduced|blocked"
    refute_match(/^Workflow-Status:/, certificate)
  end

  def test_prompts_preserve_repository_authority_and_short_circuit_terminal_statuses
    prompt_corpus.each do |name, prompt|
      assert_includes prompt, "tools/repository-state.rb", name
      assert_match(/untrusted/i, prompt, name)
      assert_match(/uncommitted/i, prompt, name)
      assert_match(/refs? unchanged/i, prompt, name)
    end

    %w[diagnose repair revise-repair certificate].each do |name|
      prompt = instruction(name)
      assert_includes prompt, "not-reproduced", name
      assert_includes prompt, "blocked", name
      assert_match(/no-op|do not run|do not execute/i, prompt, name)
    end
  end

  def test_prompts_prohibit_destructive_history_and_release_operations
    corpus = prompt_corpus.map(&:last).join("\n")

    PROHIBITED_OPERATIONS.each do |operation|
      assert_match(/\b#{Regexp.escape(operation)}\b/i, corpus, operation)
    end
    assert_match(/do not|never|prohibit/i, corpus)
  end

  def test_readme_discloses_high_risk_local_mutation_and_unpublished_status
    readme = File.read(File.join(PACKAGE_ROOT, "README.md"))

    %w[arbitrary local command high-risk mutation uncommitted].each do |phrase|
      assert_includes readme.downcase, phrase, phrase
    end
    assert_match(/sole.*owner.*authority|owner.*sole.*authority/i, readme)
    assert_match(/unpublished/i, readme)
    assert_match(/no manifest|manifest.*not.*present/i, readme)
  end

  def test_terminal_evidence_fixtures_enforce_semantic_outcomes
    verified = certificate_fixture("verified")
    assert_equal "verified", verified.fetch("Outcome")
    assert_equal "failed", verified.fetch("Focused-Regression-Before")
    assert_equal "passed", verified.fetch("Focused-Regression-After")
    assert_equal "passed", verified.fetch("Adjacent-Checks")
    assert_equal "ready", verified.fetch("Causal-Consensus")
    assert_equal "true", verified.fetch("Refs-Unchanged")
    assert_equal "true", verified.fetch("Repair-Attempted")
    refute_equal repository_fingerprint(verified, "Baseline"), repository_fingerprint(verified, "Terminal")
    assert_equal 1, verified.fetch("__source").scan(/^Terminal-Repository-State:/).length

    not_reproduced = certificate_fixture("not-reproduced")
    assert_equal "not-reproduced", not_reproduced.fetch("Outcome")
    assert_equal "not-reproduced", not_reproduced.fetch("Reproduction-Before")
    assert_equal "false", not_reproduced.fetch("Repair-Attempted")
    assert_equal "none", not_reproduced.fetch("Uncommitted-Changes")
    assert_equal repository_fingerprint(not_reproduced, "Baseline"),
                 repository_fingerprint(not_reproduced, "Terminal")

    blocked = certificate_fixture("blocked")
    assert_equal "blocked", blocked.fetch("Outcome")
    assert_equal "true", blocked.fetch("Manual-Only")
    assert_equal "false", blocked.fetch("Repair-Attempted")
    refute_empty blocked.fetch("Blocker")

    cap = certificate_fixture("cap")
    assert_equal "blocked", cap.fetch("Outcome")
    assert_equal "max-rounds", cap.fetch("Council-Status")
    assert_equal "unresolved", cap.fetch("Causal-Consensus")
    assert_operator Integer(cap.fetch("Unresolved-Findings"), 10), :>, 0
    refute_match(/^Outcome: verified$/m, cap.fetch("__source"))
  end

  def test_ephemeral_manifest_binds_reachable_source_and_projects_high_risk_contract
    with_ephemeral_registry do |registry, package, manifest, source_revision, release_revision|
      assert_equal "2", git!(registry, "rev-list", "--count", "HEAD").strip
      assert_equal source_revision, git!(registry, "rev-parse", "HEAD^").strip
      assert git_success?(registry, "merge-base", "--is-ancestor", source_revision, release_revision)
      assert_equal source_revision, manifest.dig("source", "revision")
      assert_equal "high", manifest.dig("permissions", "risk")
      %w[network_hosts filesystem_read filesystem_write secrets].each do |key|
        assert_equal ["*"], manifest.dig("permissions", key), key
      end
      assert_equal SEMANTIC_SLOTS, executable_slots(load_workflow).keys
      assert_equal [{"path" => "tools/repository-state.rb"}], manifest.dig("x-hive", "tools")
      assert_equal [{"path" => "assets/evidence-contract.md"}], manifest.dig("x-hive", "prompt_assets")
      assert_empty manifest.dig("x-hive", "optional_inputs")
      assert_empty manifest.dig("x-security", "suppressions")
      assert_empty manifest.dig("x-security", "network_host_reasons")
      assert_equal HoneycombRegistry::CanonicalYAML.dump_manifest(manifest), File.binread(package.manifest_path)
      refute File.exist?(File.join(PACKAGE_ROOT, "manifest.yml"))
    end
  end

  def test_every_behavior_and_tool_byte_is_bound_by_the_ephemeral_manifest
    with_ephemeral_registry do |_registry, package, _manifest, _source_revision, _release_revision|
      BEHAVIOR_PATHS.each_with_index do |relative, index|
        path = File.join(package.path, relative)
        original = File.binread(path)
        File.binwrite(path, original + "\n# deterministic tamper #{index}\n")

        findings = HoneycombRegistry::Validator.validate(package, hive_loader: -> { nil })
        assert findings.errors?, relative
        assert_includes findings.codes, "integrity.digest_mismatch", relative
        assert_includes HoneycombRegistry::Manifest.check(package).findings.codes, "manifest.drift", relative
      ensure
        File.binwrite(path, original) if path && original
      end

      clean = HoneycombRegistry::Validator.validate(package, hive_loader: -> { nil })
      refute clean.errors?, clean.to_h.inspect
    end
  end

  def test_ephemeral_package_passes_security_lint_without_suppression_requests
    with_ephemeral_registry do |registry, package, _manifest, source_revision, release_revision|
      change_set = Struct.new(:root) do
        def between(_base, _head)
          HoneycombSecurityLint::ChangeSet::Result.new(
            version_roots: ["packages/root-cause-repair/1.0.0"], paths: [], existing_version_roots: []
          )
        end
      end.new(registry)
      validator = Struct.new(:package) do
        def validate(_path)
          findings = HoneycombRegistry::Validator.validate(package, hive_loader: -> { nil })
          HoneycombSecurityLint::ValidatorAdapter::Result.new(
            exit_status: findings.errors? ? 1 : 0, findings: findings.to_h, operational_error: nil
          )
        end
      end.new(package)
      context = {
        pull_request: 1, base_sha: source_revision, head_sha: release_revision,
        action: "labeled", gate: "applied", label_sha: release_revision,
        run_id: 1, run_attempt: 1, repository: "hive-sh/honeycomb"
      }
      result = HoneycombSecurityLint::Runner.new(
        root: registry, context: context,
        policy_path: File.join(ROOT, "policy", "security-lint.yml"),
        change_set: change_set, validator: validator
      ).run

      assert_equal "pass", result.evidence.fetch("state"), result.json
      package_evidence = result.evidence.fetch("packages").fetch(0)
      assert_empty package_evidence.fetch("suppressions")
      assert_equal "high", package_evidence.dig("requested_permissions", "risk")
    end
  end

  private

  def load_workflow
    HoneycombRegistry::SafeYAML.load_file(File.join(PACKAGE_ROOT, "workflow.yml"))
  end

  def stage_names(workflow)
    workflow.fetch("stages").map { |item| item.fetch("name") }
  end

  def stage(name)
    load_workflow.fetch("stages").find { |item| item.fetch("name") == name }
  end

  def assert_stage(name, **expected)
    item = stage(name)
    expected.each { |key, value| assert_equal value, item.fetch(key.to_s), "#{name}.#{key}" }
  end

  def instruction(name)
    File.read(File.join(PACKAGE_ROOT, "instructions", "#{name}.md"))
  end

  def prompt_corpus
    prompts = %w[reproduce diagnose repair revise-repair certificate].map do |name|
      [name, instruction(name)]
    end
    prompts << ["causal-verifier", instruction("verify")]
  end

  def executable_slots(workflow)
    workflow.fetch("stages").each_with_object({}) do |item, slots|
      next unless %w[agent council].include?(item.fetch("kind"))

      stage_id = "stages.#{item.fetch("name")}"
      slots[stage_id] = item
      item.fetch("reviewers", []).each do |reviewer|
        slots["#{stage_id}.reviewers.#{reviewer.fetch("name")}"] = reviewer
      end
      reviser = item.dig("council", "revise")
      slots["#{stage_id}.revise"] = reviser if reviser
    end
  end

  def recursive_keys(value)
    case value
    when Hash
      value.flat_map { |key, child| [key] + recursive_keys(child) }
    when Array
      value.flat_map { |child| recursive_keys(child) }
    else
      []
    end
  end

  def certificate_fixture(name)
    source = File.binread(fixture_path("managed-repair", "root-cause", name, "repair-certificate.md"))
    fields = source.lines(chomp: true).filter_map do |line|
      match = /\A([A-Za-z][A-Za-z-]*):\s*(.*)\z/.match(line)
      [match[1], match[2]] if match
    end.to_h
    assert_match(/\AOutcome: (?:verified|not-reproduced|blocked)\n/, source, name)
    assert_equal 1, source.scan(/^Outcome:/).length, name
    fields["__source"] = source
    fields
  end

  def repository_fingerprint(certificate, label)
    state = JSON.parse(certificate.fetch("#{label}-Repository-State"))
    assert_equal "honeycomb-repository-state/v1", state.fetch("schema")
    assert_equal "ok", state.fetch("status")
    assert_match(/\Asha256:[0-9a-f]{64}\z/, state.fetch("fingerprint"))
    state.fetch("fingerprint")
  end

  def with_ephemeral_registry
    Dir.mktmpdir("honeycomb-root-cause-manifest") do |registry|
      git!(registry, "init", "-q", "-b", "main")
      git!(registry, "config", "user.email", "root-cause@example.test")
      git!(registry, "config", "user.name", "Root Cause fixture")
      destination = File.join(registry, "packages", "root-cause-repair", "1.0.0")
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp_r(PACKAGE_ROOT, destination)
      FileUtils.rm_f(File.join(destination, "manifest.yml"))
      git!(registry, "add", "packages")
      git!(registry, "commit", "-qm", "ephemeral behavior source")
      source_revision = git!(registry, "rev-parse", "HEAD").strip

      package = HoneycombRegistry::Package.new(destination, root: registry)
      File.write(package.manifest_path, Psych.dump(manifest_metadata(source_revision)))
      result = HoneycombRegistry::Manifest.generate(package)
      refute result.findings.errors?, result.findings.to_h.inspect
      git!(registry, "add", package.relative_manifest_path)
      git!(registry, "commit", "-qm", "ephemeral canonical manifest")
      release_revision = git!(registry, "rev-parse", "HEAD").strip

      yield registry, package, result.document, source_revision, release_revision
    ensure
      FileUtils.chmod_R(0o700, registry) if File.exist?(registry)
    end
  end

  def manifest_metadata(source_revision)
    {
      "schema" => "honeycomb-manifest/v1",
      "name" => "root-cause-repair",
      "version" => "1.0.0",
      "description" => "Root cause diagnosis, uncommitted repair, and deterministic evidence fixture",
      "author" => {"name" => "Honeycomb maintainers", "url" => "https://example.test/honeycomb"},
      "license" => "MIT",
      "hive_min_version" => "0.6.0",
      "source" => {
        "url" => "https://example.test/honeycomb/commit/#{source_revision}",
        "revision" => source_revision
      },
      "x-hive" => {
        "tools" => [{"path" => "tools/repository-state.rb"}],
        "prompt_assets" => [{"path" => "assets/evidence-contract.md"}],
        "optional_inputs" => []
      },
      "x-security" => {"network_host_reasons" => {}, "suppressions" => []}
    }
  end

  def git!(directory, *arguments)
    stdout, stderr, status = Open3.capture3("git", *arguments, chdir: directory)
    raise "git #{arguments.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end

  def git_success?(directory, *arguments)
    _stdout, _stderr, status = Open3.capture3("git", *arguments, chdir: directory)
    status.success?
  end
end
