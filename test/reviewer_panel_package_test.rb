# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "honeycomb_security_lint"
require "psych"

class ReviewerPanelPackageTest < Minitest::Test
  PACKAGE_ROOT = File.join(ROOT, "candidates", "reviewer-panel", "1.0.0")
  IDENTITY_KEYS = %w[agent model effort].freeze
  REVIEWERS = %w[correctness security reliability test-evidence].freeze
  SEMANTIC_SLOTS = %w[
    stages.basis
    stages.panel
    stages.panel.reviewers.correctness
    stages.panel.reviewers.security
    stages.panel.reviewers.reliability
    stages.panel.reviewers.test-evidence
    stages.panel.revise
    stages.readiness
  ].freeze
  BEHAVIOR_PATHS = %w[
    workflow.yml
    README.md
    instructions/basis.md
    instructions/review-correctness.md
    instructions/review-security.md
    instructions/review-reliability.md
    instructions/review-test-evidence.md
    instructions/repair.md
    instructions/readiness.md
    assets/evidence-contract.md
    tools/repository-state.rb
  ].freeze
  PROHIBITED_OPERATIONS = %w[
    reset clean stash revert commit push PR merge tag release publish deploy
  ].freeze

  def test_workflow_has_the_exact_state_bound_panel_topology
    workflow = load_workflow

    assert_equal "reviewer-panel", workflow.fetch("id")
    assert_equal %w[inbox basis panel readiness], stage_names(workflow)
    assert_stage("inbox", kind: "terminal", state_file: "brief.md")
    assert_stage("basis", kind: "agent", state_file: "review-basis.md", instruction: "instructions/basis.md")

    panel = stage("panel")
    assert_equal "council", panel.fetch("kind")
    assert_equal "panel.md", panel.fetch("state_file")
    assert_equal "review-basis.md", panel.fetch("input")
    assert_equal REVIEWERS, panel.fetch("reviewers").map { |reviewer| reviewer.fetch("name") }
    assert_equal REVIEWERS, panel.fetch("reviewers").map { |reviewer| reviewer.fetch("output_basename") }
    assert_equal 4, panel.dig("council", "quorum")
    assert_equal 4, panel.dig("council", "max_rounds")
    assert_equal "consensus", panel.dig("council", "exit_rule")
    assert_equal "complete", panel.dig("council", "on_max_rounds")
    assert_equal "reviews/triage.md", panel.dig("council", "triage_output")
    assert_equal "instructions/repair.md", panel.dig("council", "revise", "instruction")

    assert_stage("readiness", kind: "agent", state_file: "merge-readiness.md",
                 instruction: "instructions/readiness.md", deliverable: "merge-readiness.md")
  end

  def test_every_actor_is_uniquely_mapped_without_embedded_execution_identity
    expected_roles = {
      "stages.basis" => "development",
      "stages.panel" => "reviewer",
      "stages.panel.reviewers.correctness" => "reviewer",
      "stages.panel.reviewers.security" => "reviewer",
      "stages.panel.reviewers.reliability" => "reviewer",
      "stages.panel.reviewers.test-evidence" => "reviewer",
      "stages.panel.revise" => "development",
      "stages.readiness" => "reviewer"
    }
    actors = executable_slots(load_workflow)

    assert_equal SEMANTIC_SLOTS, actors.keys
    assert_empty recursive_keys(load_workflow) & IDENTITY_KEYS
    assert_equal actors.length, actors.values.map { |actor| actor.fetch("mapping_contract") }.uniq.length
    actors.each do |slot_id, actor|
      assert_equal expected_roles.fetch(slot_id), actor.fetch("mapping_role"), slot_id
      assert_match HoneycombRegistry::HiveCompatibility::MAPPING_CONTRACT_PATTERN,
                   actor.fetch("mapping_contract"), slot_id
      assert_empty actor.keys & IDENTITY_KEYS, slot_id
    end
  end

  def test_permissions_match_actual_mutation_and_lens_boundaries
    panel = stage("panel")
    assert_equal "yolo", stage("basis").fetch("permissions")
    assert_equal "read-only", panel.fetch("permissions")
    assert_equal "yolo", panel.dig("council", "revise", "permissions")
    assert_equal "yolo", stage("readiness").fetch("permissions")

    panel.fetch("reviewers").each do |reviewer|
      if reviewer.fetch("name") == "test-evidence"
        assert_equal "yolo", reviewer.fetch("permissions")
        next
      end

      permissions = reviewer.fetch("permissions")
      assert_equal "scoped", permissions.fetch("preset")
      assert_equal ["../../../.."], permissions.fetch("dirs")
      assert_equal %w[Read LS Grep Glob], permissions.fetch("tools").first(4)
      assert_equal "Edit(./reviews/#{reviewer.fetch('name')}-*.md)", permissions.fetch("tools").last
    end

    projection = HoneycombRegistry::Permissions.derive(load_workflow)
    refute projection.findings.errors?, projection.findings.to_h.inspect
    assert_equal "high", projection.permissions.fetch("risk")
    %w[network_hosts filesystem_read filesystem_write secrets].each do |field|
      assert_equal ["*"], projection.permissions.fetch(field), field
    end
  end

  def test_reviewer_instructions_are_package_local_and_enforce_one_state_bound_lens
    stage("panel").fetch("reviewers").each do |reviewer|
      path = reviewer.fetch("instruction")
      assert_equal "instructions/review-#{reviewer.fetch('name')}.md", path

      prompt = File.read(File.join(PACKAGE_ROOT, path))
      assert_includes prompt, "Verdict: ready|changes_requested"
      assert_includes prompt, "Basis-Digest:"
      assert_includes prompt, "Repository-Fingerprint:"
      assert_match(/stable finding id|stable `?Finding-ID/i, prompt)
      assert_match(/untrusted/i, prompt)
      assert_match(/analytical/i, prompt)
      refute_match(/^Outcome:/, prompt)
    end
  end

  def test_basis_repair_and_readiness_preserve_state_ledger_and_authority
    corpus = %w[basis repair readiness].to_h do |name|
      [name, instruction(name)]
    end

    corpus.each do |name, prompt|
      assert_includes prompt, "tools/repository-state.rb", name
      assert_includes prompt, "Basis-Digest:", name
      assert_match(/untrusted/i, prompt, name)
      assert_match(/refs? unchanged/i, prompt, name)
      assert_match(/uncommitted/i, prompt, name)
      assert_match(/bounded|truncate/i, prompt, name)
      assert_match(/redact/i, prompt, name)
    end

    repair = corpus.fetch("repair")
    %w[resolved deferred rejected].each { |disposition| assert_includes repair, disposition }
    assert_match(/all four|four.*lens/i, repair)

    readiness = corpus.fetch("readiness")
    assert_includes readiness, "Outcome: ready|changes-requested|inconclusive|state-stale"
    assert_match(/not.*merge approval|never.*merge approval/i, readiness)
    %w[inconclusive state-stale].each { |status| assert_includes readiness, status }

    all_prompts = prompt_corpus.join("\n")
    PROHIBITED_OPERATIONS.each do |operation|
      assert_match(/\b#{Regexp.escape(operation)}\b/i, all_prompts, operation)
    end
  end

  def test_readme_discloses_the_local_high_risk_analytical_only_candidate
    readme = File.read(File.join(PACKAGE_ROOT, "README.md"))

    %w[unpublished high-risk uncommitted mutation analytical].each do |term|
      assert_includes readme.downcase, term
    end
    assert_match(/four.*semantic.*lens|semantic.*lenses/i, readme)
    assert_match(/same.*execution profile|one.*agent/i, readme)
    assert_match(/owner.*sole.*authority|sole.*owner.*authority/i, readme)
    assert_match(/no manifest|manifest.*not.*present/i, readme)
    assert_match(/not.*human approval|not.*merge approval/i, readme)
  end

  def test_terminal_fixtures_enforce_state_bound_analytical_outcomes
    ready = readiness_fixture("ready")
    ready_fingerprint = repository_fingerprint(ready, "Terminal")
    assert_equal "ready", ready.fetch("Outcome")
    assert_equal "passed", ready.fetch("Required-Verification")
    assert_equal "true", ready.fetch("Refs-Unchanged")
    assert_equal "true", ready.fetch("Workflow-Repair-Uncommitted")
    assert_equal "committed", ready.fetch("Original-Change-State")
    refute_equal "none", ready.fetch("Comparison-Base")
    assert_equal "true", ready.fetch("Finding-IDs-Stable")
    assert_equal "resolved", finding_disposition(ready, "Finding-RP-COR-001")
    assert_includes ready.fetch("Finding-RP-COR-001"), "repair="
    assert_includes ready.fetch("Finding-RP-COR-001"), "verification="
    assert_includes ready.fetch("Finding-History-RP-COR-001"), "RP-COR-001"
    assert_equal "true", ready.fetch("Analytical-Only")
    assert_equal "sole-owner", ready.fetch("Owner-Authority")
    assert_equal "false", ready.fetch("Human-Approval")
    assert_equal "4/4", ready.fetch("Quorum")
    assert_lenses_bound_to(ready, expected_verdicts: REVIEWERS.to_h { |lens| [lens, "ready"] },
                          fingerprint: ready_fingerprint)

    changes = readiness_fixture("changes-requested")
    changes_fingerprint = repository_fingerprint(changes, "Terminal")
    assert_equal "changes-requested", changes.fetch("Outcome")
    assert_equal "reached", changes.fetch("Repair-Round-Cap")
    assert_equal "3/4", changes.fetch("Quorum")
    assert_equal "RP-SEC-004", changes.fetch("Unresolved-Blocking")
    assert_equal "rejected", finding_disposition(changes, "Finding-RP-SEC-004")
    assert_equal "insufficient", changes.fetch("Rejection-Evidence")
    assert_lenses_bound_to(
      changes,
      expected_verdicts: {
        "correctness" => "ready", "security" => "changes_requested",
        "reliability" => "ready", "test-evidence" => "ready"
      },
      fingerprint: changes_fingerprint
    )

    inconclusive = readiness_fixture("inconclusive")
    assert_equal "inconclusive", inconclusive.fetch("Outcome")
    assert_equal "true", inconclusive.fetch("Required-Environment-Unavailable")
    assert_equal "true", inconclusive.fetch("Clean-Repository")
    assert_equal "none", inconclusive.fetch("Comparison-Base")
    assert_equal "false", inconclusive.fetch("Repair-Attempted")

    stale = readiness_fixture("state-stale")
    assert_equal "state-stale", stale.fetch("Outcome")
    assert_equal "test-evidence", stale.fetch("Drift-Source")
    assert_equal "true", stale.fetch("External-Or-Test-Mutation")
    refute_equal repository_fingerprint(stale, "Reviewed"), repository_fingerprint(stale, "Terminal")
    assert_equal "false", stale.fetch("Repair-Absorbed-Drift")

    %w[ready changes-requested inconclusive state-stale].each do |name|
      fixture = readiness_fixture(name)
      assert_equal "true", fixture.fetch("Analytical-Only"), name
      assert_equal "sole-owner", fixture.fetch("Owner-Authority"), name
      assert_equal "false", fixture.fetch("Human-Approval"), name
      assert_match(/not human/i, fixture.fetch("__source"), name)
      assert_match(/merge\s+approval/i, fixture.fetch("__source"), name)
    end
  end

  def test_ephemeral_manifest_binds_reachable_source_and_exact_runtime_contract
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

      bounded_reviewers.each do |reviewer|
        result = HoneycombRegistry::Permissions.derive(
          {"stages" => [{"kind" => "agent", "permissions" => reviewer.fetch("permissions")}]}
        )
        refute result.findings.errors?, result.findings.to_h.inspect
        assert_equal "moderate", result.permissions.fetch("risk"), reviewer.fetch("name")
        assert_equal ["repository", "task"], result.permissions.fetch("filesystem_read")
        assert_equal ["task/reviews/#{reviewer.fetch('name')}-*.md"],
                     result.permissions.fetch("filesystem_write")
        assert_empty result.permissions.fetch("network_hosts")
        assert_empty result.permissions.fetch("secrets")
      end
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

  def test_ephemeral_package_passes_security_lint_without_suppressions
    with_ephemeral_registry do |registry, package, _manifest, source_revision, release_revision|
      change_set = Struct.new(:root) do
        def between(_base, _head)
          HoneycombSecurityLint::ChangeSet::Result.new(
            version_roots: ["packages/reviewer-panel/1.0.0"], paths: [], existing_version_roots: []
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
    paths = Dir[File.join(PACKAGE_ROOT, "instructions", "*.md")]
    paths.sort.map { |path| File.read(path) }
  end

  def executable_slots(workflow)
    workflow.fetch("stages").each_with_object({}) do |item, slots|
      next unless %w[agent council].include?(item.fetch("kind"))

      stage_id = "stages.#{item.fetch('name')}"
      slots[stage_id] = item
      item.fetch("reviewers", []).each do |reviewer|
        slots["#{stage_id}.reviewers.#{reviewer.fetch('name')}"] = reviewer
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

  def readiness_fixture(name)
    source = File.binread(fixture_path("managed-repair", "reviewer-panel", name, "merge-readiness.md"))
    fields = source.lines(chomp: true).filter_map do |line|
      match = /\A([A-Za-z][A-Za-z0-9-]*):\s*(.*)\z/.match(line)
      [match[1], match[2]] if match
    end.to_h
    assert_match(/\AOutcome: (?:ready|changes-requested|inconclusive|state-stale)\n/, source, name)
    assert_equal 1, source.scan(/^Outcome:/).length, name
    fields["__source"] = source
    fields
  end

  def repository_fingerprint(readiness, label)
    state = JSON.parse(readiness.fetch("#{label}-Repository-State"))
    assert_equal "honeycomb-repository-state/v1", state.fetch("schema")
    assert_equal "ok", state.fetch("status")
    assert_match(/\Asha256:[0-9a-f]{64}\z/, state.fetch("fingerprint"))
    state.fetch("fingerprint")
  end

  def finding_disposition(readiness, field)
    readiness.fetch(field).split("|", 2).first
  end

  def assert_lenses_bound_to(readiness, expected_verdicts:, fingerprint:)
    basis_digest = readiness.fetch("Basis-Digest")
    assert_match(/\Asha256:[0-9a-f]{64}\z/, basis_digest)
    assert_equal REVIEWERS, expected_verdicts.keys
    REVIEWERS.each do |lens|
      verdict, cited_basis, cited_fingerprint = readiness.fetch("Lens-#{lens}").split("|", 3)
      assert_equal expected_verdicts.fetch(lens), verdict, lens
      assert_equal basis_digest, cited_basis, lens
      assert_equal fingerprint, cited_fingerprint, lens
    end
  end

  def bounded_reviewers
    stage("panel").fetch("reviewers").first(3)
  end

  def with_ephemeral_registry
    Dir.mktmpdir("honeycomb-reviewer-panel-manifest") do |registry|
      git!(registry, "init", "-q", "-b", "main")
      git!(registry, "config", "user.email", "reviewer-panel@example.test")
      git!(registry, "config", "user.name", "Reviewer Panel fixture")
      destination = File.join(registry, "packages", "reviewer-panel", "1.0.0")
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
      "name" => "reviewer-panel",
      "version" => "1.0.0",
      "description" => "State-bound four-lens review and uncommitted repair fixture",
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
