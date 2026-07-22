# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "json"
require "yaml"

REVIEWER_PANEL_HIVE_REVISION = "af22485f9b2bee27a7497dc138e5e58ab9725bde"
reviewer_panel_hive_source = ENV["HONEYCOMB_HIVE_SOURCE"].to_s
REVIEWER_PANEL_HIVE_PRECHECK_ERROR = begin
  if reviewer_panel_hive_source.empty?
    "HONEYCOMB_HIVE_SOURCE must name the pinned Hive checkout"
  elsif !File.directory?(File.join(reviewer_panel_hive_source, "lib"))
    "HONEYCOMB_HIVE_SOURCE does not contain Hive lib/"
  else
    head, head_error, head_status = Open3.capture3("git", "-C", reviewer_panel_hive_source, "rev-parse", "HEAD")
    dirty, dirty_error, dirty_status = Open3.capture3(
      "git", "-C", reviewer_panel_hive_source, "status", "--porcelain=v1", "--untracked-files=all"
    )
    flags, flags_error, flags_status = Open3.capture3(
      "git", "-C", reviewer_panel_hive_source, "ls-files", "-v", "-f", "-z"
    )
    hidden_flag = flags.split("\0").find { |entry| !entry.empty? && entry.getbyte(0) != "H".ord }
    if !head_status.success?
      "cannot read Hive revision: #{head_error.strip}"
    elsif head.strip != REVIEWER_PANEL_HIVE_REVISION
      "Hive revision #{head.strip.inspect} is not #{REVIEWER_PANEL_HIVE_REVISION}"
    elsif !dirty_status.success?
      "cannot inspect Hive checkout: #{dirty_error.strip}"
    elsif !flags_status.success?
      "cannot inspect Hive index flags: #{flags_error.strip}"
    elsif hidden_flag
      "Hive checkout must not use non-default index flags; found #{hidden_flag.byteslice(0, 1).inspect}"
    elsif !dirty.empty?
      "Hive checkout must be clean; status is #{dirty.lines.first.to_s.strip.inspect}"
    end
  end
end

$LOAD_PATH.unshift(File.join(reviewer_panel_hive_source, "lib")) if REVIEWER_PANEL_HIVE_PRECHECK_ERROR.nil?
REVIEWER_PANEL_HIVE_LOAD_ERROR = begin
  if REVIEWER_PANEL_HIVE_PRECHECK_ERROR.nil?
    require "hive"
    require "hive/commands/new"
    require "hive/commands/workflow/install"
    require "hive/markers"
    require "hive/stages/agent"
    require "hive/stages/council"
    require "hive/task"
    require "hive/workflow_package/managed_store"
    require "hive/workflow_package/registry_client"
  end
  nil
rescue LoadError => e
  e
end

class ReviewerPanelHiveExecutionTest < Minitest::Test
  PACKAGE_NAME = "reviewer-panel"
  PACKAGE_VERSION = "1.0.0"
  PACKAGE_ROOT = File.join(ROOT, "packages", PACKAGE_NAME, PACKAGE_VERSION)
  LENSES = %w[correctness security reliability test-evidence].freeze
  MAPPING_SLOTS = %w[
    stages.basis
    stages.panel
    stages.panel.reviewers.correctness
    stages.panel.reviewers.security
    stages.panel.reviewers.reliability
    stages.panel.reviewers.test-evidence
    stages.panel.revise
    stages.readiness
  ].freeze

  def setup
    assert_nil REVIEWER_PANEL_HIVE_PRECHECK_ERROR, REVIEWER_PANEL_HIVE_PRECHECK_ERROR
    assert_nil REVIEWER_PANEL_HIVE_LOAD_ERROR,
               "pinned Hive could not be loaded: #{REVIEWER_PANEL_HIVE_LOAD_ERROR&.message}"
    @repository_state_slots = []
  end

  def test_install_rejects_incompatible_mapping_requires_escalation_and_pins_runtime
    with_sandbox("repairable") do |registry, project, _comparison_base|
      client = Hive::WorkflowPackage::RegistryClient.new(repository: registry)
      incompatible = assert_raises(Hive::ConfigError) do
        install(client, project, agent: "codex", allow_escalation: true)
      end
      assert_match(/cannot enforce|tool scop|permission/i, incompatible.message)
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(project, ".hive-state"))
      assert_nil store.selected(PACKAGE_NAME, cfg: Hive::Config.load(project))

      consent = assert_raises(Hive::Commands::Workflow::ConsentRequired) do
        install(client, project, agent: "claude", allow_escalation: false)
      end
      assert_match(/unbounded\/high-risk.*--allow-escalation/i, consent.message)
      assert_nil store.selected(PACKAGE_NAME, cfg: Hive::Config.load(project))

      payload = install(client, project, agent: "claude", allow_escalation: true)
      assert_equal "installed", payload.fetch("status")
      assert_equal "high", payload.dig("permissions", "risk")
      assert_equal MAPPING_SLOTS.sort, payload.fetch("mappings").map { |entry| entry.fetch("slot") }
      assert payload.fetch("mappings").all? { |entry| entry.fetch("agent") == "claude" }

      path = create_task(project, "panel-install", nil)
      task = Hive::Task.new(path)
      assert_equal payload.fetch("catalog_commit"), task.workflow_commit
      assert_equal payload.fetch("manifest_digest"), task.workflow_manifest_digest
      assert_equal payload.fetch("configuration_digest"), task.workflow_configuration_digest
      assert_equal ["claude"], executable_agents(task.workflow).values.uniq

      context = task.managed_runtime_context("stages.basis")
      tool = context.fetch(:tools).find { |candidate| File.basename(candidate) == "repository-state.rb" }
      assert File.executable?(tool), "installed repository-state tool must retain mode 100755"
      assert_equal "ok", capture_repository_state(task, "stages.basis").fetch("status")
    end
  end

  def test_repairable_blockers_are_repaired_then_all_lenses_rerun_on_one_basis
    with_installed_task("repairable", :repairable) do |project, path, payload, runtime|
      authority = target_authority(project)
      final_path = with_deterministic_agents(:repairable, runtime) { run_workflow(project, path) }

      readiness = File.read(File.join(final_path, "merge-readiness.md"))
      assert_match(/\AOutcome: ready\n/, readiness)
      assert_includes readiness, "Analytical-Only: true"
      assert_includes readiness, "Human-Approval: false"
      assert_equal 1, runtime.fetch(:revisions)
      assert_equal 8, runtime.fetch(:review_records).length
      assert_equal [1, 2], runtime.fetch(:test_evidence_runs).map { |run| run.fetch("round") }
      assert runtime.fetch(:test_evidence_runs).all? { |run| run.fetch("status") == "passed" }
      assert_equal 1, runtime.fetch(:readiness_runs).length
      assert_equal "passed", runtime.fetch(:readiness_runs).first.fetch("status")
      assert_includes readiness, "Terminal-Verification-Status: passed"
      assert_equal [:claude], runtime.fetch(:launches).map { |launch| launch.fetch(:agent) }.uniq
      scoped = runtime.fetch(:launches).select do |launch|
        %w[panel-correctness panel-security panel-reliability].include?(launch.fetch(:log_label))
      end
      assert_equal 6, scoped.length
      scoped.each do |launch|
        assert_equal "dontAsk", launch.fetch(:permission_mode)
        %w[Read LS Grep Glob].each { |tool| assert_includes launch.fetch(:allowed_tools), tool }
        assert launch.fetch(:allowed_tools).any? { |tool| tool.start_with?("Edit(") }
        assert_includes launch.fetch(:disallowed_tools), "Bash"
        assert_includes launch.fetch(:add_dirs), File.realpath(project)
      end

      final_pass = runtime.fetch(:review_records).select { |record| record.fetch(:round) == 2 }
      assert_equal LENSES, final_pass.map { |record| record.fetch(:lens) }
      assert_equal ["ready"], final_pass.map { |record| record.fetch(:verdict) }.uniq
      assert_equal 1, final_pass.map { |record| record.fetch(:basis) }.uniq.length
      assert_equal 1, final_pass.map { |record| record.fetch(:fingerprint) }.uniq.length
      refute_equal runtime.fetch(:review_records).first.fetch(:basis), final_pass.first.fetch(:basis)
      basis = File.read(File.join(final_path, "review-basis.md"))
      %w[RP-COR-001 RP-TST-002 resolved lib/value.rb test/value_check.rb].each do |evidence|
        assert_includes basis, evidence
      end

      assert_includes File.read(File.join(project, "lib", "value.rb")), "42"
      assert File.file?(File.join(project, "test", "value_check.rb"))
      assert_test_passes(project, "test/value_check.rb")
      status = git!(project, "status", "--short")
      assert_match(/test\/value_check.rb/, status)
      assert_equal authority, target_authority(project)
      assert_equal payload.fetch("catalog_commit"), Hive::Task.new(final_path).workflow_commit

      panel_path = move_task_to_stage(project, final_path, "panel")
      before = runtime.slice(:revisions, :spawns, :review_records)
      result = with_deterministic_agents(:repairable, runtime) do
        Hive::Stages::Council.run!(Hive::Task.new(panel_path), {})
      end
      assert_equal :complete, result.fetch(:status)
      assert_equal before, runtime.slice(:revisions, :spawns, :review_records)
      assert_equal authority, target_authority(project)
    end
  end

  def test_explicit_base_committed_change_is_ready_without_uncommitted_repair
    with_installed_task("committed-change", :committed_change) do |project, path, _payload, runtime|
      authority = target_authority(project)
      comparison_base = runtime.fetch(:comparison_base)
      assert git_success?(project, "merge-base", "--is-ancestor", comparison_base, "HEAD")
      assert_equal "2", git!(project, "rev-list", "--count", "HEAD").strip

      final_path = with_deterministic_agents(:committed_change, runtime) { run_workflow(project, path) }
      readiness = File.read(File.join(final_path, "merge-readiness.md"))
      assert_match(/\AOutcome: ready\n/, readiness)
      assert_includes readiness, "Comparison-Base: #{comparison_base}"
      assert_includes readiness, "Original-Change-State: committed"
      assert_equal 4, runtime.fetch(:review_records).length
      assert_equal 0, runtime.fetch(:revisions)
      assert_equal 1, runtime.fetch(:test_evidence_runs).length
      assert_equal 1, runtime.fetch(:readiness_runs).length
      assert_equal "passed", runtime.fetch(:readiness_runs).first.fetch("status")
      assert_empty git!(project, "status", "--porcelain=v1")
      assert_equal authority, target_authority(project)
    end
  end

  def test_three_ready_lenses_cannot_outvote_blocker_and_only_three_repairs_run
    with_installed_task("unresolved", :unresolved) do |project, path, _payload, runtime|
      authority = target_authority(project)
      final_path = with_deterministic_agents(:unresolved, runtime) { run_workflow(project, path) }
      readiness = File.read(File.join(final_path, "merge-readiness.md"))

      assert_match(/\AOutcome: changes-requested\n/, readiness)
      assert_includes readiness, "Unresolved-Blocking: RP-SEC-004"
      assert_includes readiness, "Disposition: rejected"
      assert_includes readiness, "Rejection-Evidence: unsupported"
      assert_equal 3, runtime.fetch(:revisions), "four review passes permit only three repairs"
      assert_equal 16, runtime.fetch(:review_records).length
      assert_equal 4, runtime.fetch(:test_evidence_runs).length
      assert_empty runtime.fetch(:readiness_runs)
      (1..4).each do |round|
        records = runtime.fetch(:review_records).select { |record| record.fetch(:round) == round }
        assert_equal 3, records.count { |record| record.fetch(:verdict) == "ready" }, round
        assert_equal 1, records.count { |record| record.fetch(:verdict) == "changes_requested" }, round
      end
      marker = Hive::Markers.current(File.join(final_path, "panel.md"))
      assert_equal :complete, marker.name
      assert_equal "max_rounds", marker.attrs.fetch("reason")
      assert_equal 4, marker.attrs.fetch("round").to_i
      assert_equal authority, target_authority(project)
      assert_match(/lib\/loader\.rb/, git!(project, "status", "--short"))
    end
  end

  def test_missing_environment_is_inconclusive_without_repair
    with_environment("PANEL_REQUIRED_SERVICE" => nil) do
      with_installed_task("inconclusive", :inconclusive) do |project, path, _payload, runtime|
        authority = target_authority(project)
        baseline = target_fingerprint(path)
        final_path = with_deterministic_agents(:inconclusive, runtime) { run_workflow(project, path) }
        readiness = File.read(File.join(final_path, "merge-readiness.md"))

        assert_match(/\AOutcome: inconclusive\n/, readiness)
        assert_includes readiness, "Required-Environment-Unavailable: true"
        assert_equal [{"command" => "ruby verify.rb", "status" => "unavailable"}], runtime.fetch(:intake_checks)
        assert_equal 0, runtime.fetch(:revisions)
        assert_empty runtime.fetch(:test_evidence_runs)
        assert_empty runtime.fetch(:readiness_runs)
        refute_includes @repository_state_slots, "stages.readiness"
        assert_equal baseline, target_fingerprint(final_path)
        assert_equal authority, target_authority(project)
        assert_empty git!(project, "status", "--porcelain=v1")
      end
    end
  end

  def test_test_evidence_and_between_review_mutation_are_state_stale
    %i[test_evidence_stale between_review_stale].each do |scenario|
      with_installed_task("state-stale", scenario) do |project, path, _payload, runtime|
        authority = target_authority(project)
        baseline = target_fingerprint(path)
        after_stage = if scenario == :between_review_stale
                        lambda do |stage_name|
                          File.write(File.join(project, "external-drift.txt"), "between review and readiness\n") if stage_name == "panel"
                        end
                      end
        final_path = with_deterministic_agents(scenario, runtime) do
          run_workflow(project, path, after_stage: after_stage)
        end
        readiness = File.read(File.join(final_path, "merge-readiness.md"))

        assert_match(/\AOutcome: state-stale\n/, readiness, scenario)
        assert_includes readiness, "Repair-Absorbed-Drift: false"
        refute_equal baseline, target_fingerprint(final_path)
        assert_equal 0, runtime.fetch(:revisions)
        assert_equal 1, runtime.fetch(:test_evidence_runs).length
        assert_empty runtime.fetch(:readiness_runs)
        assert_equal authority, target_authority(project)
        assert_match(/drift|test-evidence/, git!(project, "status", "--short"))
      end
    end
  end

  private

  def with_installed_task(fixture, scenario)
    with_sandbox(fixture) do |registry, project, comparison_base|
      client = Hive::WorkflowPackage::RegistryClient.new(repository: registry)
      payload = install(client, project, agent: "claude", allow_escalation: true)
      runtime = {
        comparison_base: comparison_base, revisions: 0, spawns: 0,
        review_records: [], test_evidence_runs: [], readiness_runs: [], intake_checks: [],
        launches: [], cycle: 0
      }
      yield project, create_task(project, scenario.to_s.tr("_", "-"), comparison_base), payload, runtime
    end
  end

  def with_sandbox(fixture)
    sandbox = Dir.mktmpdir("honeycomb-reviewer-panel-hive")
    registry = build_registry(File.join(sandbox, "registry"))
    home = File.join(sandbox, "hive-home")
    FileUtils.mkdir_p(home)
    File.write(File.join(home, "config.yml"), {"registered_projects" => []}.to_yaml)
    with_environment("HIVE_HOME" => home) do
      project, comparison_base = build_project(File.join(sandbox, "#{fixture}-project"), fixture)
      yield registry, project, comparison_base
    end
  ensure
    FileUtils.chmod_R(0o700, sandbox) if sandbox && File.exist?(sandbox)
    FileUtils.rm_rf(sandbox) if sandbox
    Hive::Workflows::Project.reset! if defined?(Hive::Workflows::Project)
  end

  def build_project(path, fixture)
    source = File.join(fixture_path("managed-repair", "reviewer-panel", "repos", fixture), ".")
    FileUtils.mkdir_p(path)
    FileUtils.cp_r(source, path)
    working_change = working_change_fixture(path, fixture)
    File.binwrite(working_change.fetch(:path), working_change.fetch(:baseline)) if working_change

    git!(path, "init", "-q", "-b", "main")
    git!(path, "config", "user.email", "reviewer-panel@example.test")
    git!(path, "config", "user.name", "Reviewer Panel fixture")
    git!(path, "add", ".")
    git!(path, "commit", "-qm", "seed comparison base")
    comparison_base = git!(path, "rev-parse", "HEAD").strip if fixture == "committed-change"
    if working_change
      File.binwrite(working_change.fetch(:path), working_change.fetch(:current))
    end
    if fixture == "committed-change"
      git!(path, "add", working_change.fetch(:path).delete_prefix("#{path}/"))
      git!(path, "commit", "-qm", "committed change under review")
    end

    state = File.join(path, ".hive-state")
    FileUtils.mkdir_p(File.join(state, "stages"))
    FileUtils.mkdir_p(File.join(state, "logs"))
    File.write(File.join(state, "config.yml"), Hive::Config::DEFAULTS.merge("hive_state_path" => ".hive-state").to_yaml)
    git!(state, "init", "-q", "-b", "hive-state")
    git!(state, "config", "user.email", "reviewer-panel@example.test")
    git!(state, "config", "user.name", "Reviewer Panel fixture")
    git!(state, "add", ".")
    git!(state, "commit", "-qm", "bootstrap fixture state")
    Hive::Config.register_project(name: File.basename(path), path: path, repository_identity: nil)
    [path, comparison_base]
  end

  def working_change_fixture(path, fixture)
    relative, baseline_transform = case fixture
                                   when "repairable"
                                     ["lib/value.rb", ->(body) { body.sub("41", "42") }]
                                   when "committed-change"
                                     ["lib/value.rb", ->(body) { body.sub("42", "41") }]
                                   when "unresolved"
                                     ["lib/loader.rb", ->(body) { body.sub("eval(expression)", "Integer(expression, 10)") }]
                                   when "state-stale"
                                     ["lib/value.rb", ->(body) { body.sub("42", "41") }]
                                   else
                                     return
                                   end
    target = File.join(path, relative)
    current = File.binread(target)
    {path: target, current: current, baseline: baseline_transform.call(current)}
  end

  def install(client, project, agent:, allow_escalation:)
    overrides = MAPPING_SLOTS.map { |slot| "#{slot}=#{agent}" }
    Hive::Commands::Workflow::Install.new(
      "honeycomb/#{PACKAGE_NAME}@#{PACKAGE_VERSION}", project_root: project,
      json: true, yes: true, allow_escalation: allow_escalation,
      mapping_overrides: overrides, input_bindings: [], stdout: StringIO.new,
      registry_client: client, committer: ->(*) { }
    ).call!
  end

  def create_task(project, slug, comparison_base)
    body = "Review the complete working change."
    body += " Comparison-Base: #{comparison_base}." if comparison_base
    capture_io do
      Hive::Commands::New.new(
        File.basename(project), "Run the reviewer panel", slug_override: slug,
        body_override: body, workflow: PACKAGE_NAME
      ).call!
    end
    File.join(project, ".hive-state", "stages", "1-inbox", slug)
  end

  def run_workflow(project, initial_path, after_stage: nil)
    path = initial_path
    workflow = Hive::Task.new(path).workflow
    workflow.stages.drop(1).each do |stage|
      path = move_task_to_stage(project, path, stage.name)
      task = Hive::Task.new(path)
      result = stage.kind == :council ? Hive::Stages::Council.run!(task, {}) : Hive::Stages::Agent.run!(task, {})
      assert_equal :complete, result.fetch(:status), stage.name
      after_stage&.call(stage.name)
    end
    path
  end

  def move_task_to_stage(project, current_path, stage_name)
    workflow = Hive::Task.new(current_path).workflow
    stage = workflow.stage_named(stage_name)
    parent = File.join(project, ".hive-state", "stages", stage.dir)
    FileUtils.mkdir_p(parent)
    destination = File.join(parent, File.basename(current_path))
    return current_path if File.expand_path(current_path) == File.expand_path(destination)

    FileUtils.mv(current_path, destination)
    destination
  end

  def with_deterministic_agents(scenario, runtime)
    original = Hive::Stages::Base.method(:spawn_agent)
    owner = self
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |task, **kwargs|
      owner.send(:deterministic_spawn, scenario, runtime, task, **kwargs)
    end
    yield
  ensure
    Hive::Stages::Base.define_singleton_method(:spawn_agent, original) if original
  end

  def deterministic_spawn(scenario, runtime, task, prompt:, cwd:, log_label:, expected_output: nil, **kwargs)
    runtime[:spawns] += 1
    runtime[:launches] << {
      log_label: log_label, agent: kwargs.fetch(:profile).name,
      permission_mode: kwargs[:permission_mode], allowed_tools: kwargs[:allowed_tools],
      disallowed_tools: kwargs[:disallowed_tools], add_dirs: kwargs.fetch(:add_dirs)
    }
    if expected_output
      if log_label.end_with?("-revise")
        runtime[:revisions] += 1
        repair_and_refresh_basis(task, scenario, runtime, expected_output)
      else
        write_lens_review(task, scenario, runtime, log_label, expected_output)
      end
      return {status: :ok}
    end

    output = File.join(cwd, task.workflow.stage_named(log_label).state_file)
    body = case log_label
           when "basis" then build_basis(task, scenario, runtime)
           when "readiness" then build_readiness(task, scenario, runtime)
           else raise "unexpected deterministic stage #{log_label}"
           end
    write_complete(output, body)
    {status: :ok}
  end

  def build_basis(task, scenario, runtime)
    state = capture_repository_state(task, "stages.basis")
    runtime[:cycle] += 1
    bind_runtime_basis(runtime, state)
    status = scenario == :inconclusive ? "inconclusive" : "reviewing"
    blocker = ""
    if scenario == :inconclusive
      _stdout, _stderr, required_status = Open3.capture3(RbConfig.ruby, "verify.rb", chdir: task.project_root)
      raise "inconclusive fixture required check unexpectedly passed" if required_status.success?
      runtime[:intake_checks] << {"command" => "ruby verify.rb", "status" => "unavailable"}
      blocker = <<~FIELDS
        Required-Environment-Unavailable: true
        Required-Check-Command: ruby verify.rb
        Required-Check-Status: unavailable
      FIELDS
    end
    <<~MD.chomp
      Workflow-Status: #{status}
      Comparison-Base: #{runtime[:comparison_base] || "none"}
      Basis-Digest: #{runtime.fetch(:basis)}
      Repository-Fingerprint: #{state.fetch("fingerprint")}
      #{blocker}Finding-Ledger: []
      Repository-State: #{JSON.generate(state)}
    MD
  end

  def write_lens_review(task, scenario, runtime, log_label, output)
    lens = log_label.delete_prefix("panel-")
    round = File.basename(output, ".md")[/-(\d+)\z/, 1].to_i
    basis = basis_fields(File.read(File.join(task.folder, "review-basis.md")))
    verdict = lens_verdict(scenario, lens, round)
    verification = test_evidence_for_lens(task, scenario, runtime, lens, round)
    runtime[:review_records] << {
      round: round, lens: lens, verdict: verdict,
      basis: basis.fetch("Basis-Digest"), fingerprint: basis.fetch("Repository-Fingerprint")
    }
    finding = finding_for_lens(verdict, scenario, lens)
    verification_lines = if verification
                           <<~FIELDS.chomp
                             Verification-Command: #{verification.fetch("command")}
                             Verification-Status: #{verification.fetch("status")}
                             Verification-Pre-Fingerprint: #{verification.fetch("pre_fingerprint")}
                             Verification-Post-Fingerprint: #{verification.fetch("post_fingerprint")}
                           FIELDS
                         else
                           "Verification-Status: not-run"
                         end
    FileUtils.mkdir_p(File.dirname(output))
    File.write(output, <<~MD)
      Verdict: #{verdict}
      Basis-Digest: #{basis.fetch("Basis-Digest")}
      Repository-Fingerprint: #{basis.fetch("Repository-Fingerprint")}
      Lens: #{lens}
      Finding-ID: #{finding}
      Analytical-Only: true
      Human-Approval: false
      #{verification_lines}

      ## Findings
      #{finding}

      ## Required edits
      #{verdict == "ready" ? "None." : "Resolve the blocking finding without expanding authority."}
    MD
  end

  def lens_verdict(scenario, lens, round)
    return "changes_requested" if scenario == :repairable && round == 1 && %w[correctness test-evidence].include?(lens)
    return "changes_requested" if scenario == :unresolved && lens == "security"

    "ready"
  end

  def test_evidence_for_lens(task, scenario, runtime, lens, round)
    return unless lens == "test-evidence" && scenario != :inconclusive

    verification = run_repository_verification(task, "stages.panel.reviewers.test-evidence")
    if scenario == :test_evidence_stale
      File.write(File.join(task.project_root, "test-evidence-drift.txt"), "reviewer mutated target\n")
      verification["post_fingerprint"] = capture_repository_state(
        task, "stages.panel.reviewers.test-evidence"
      ).fetch("fingerprint")
    end
    verification["round"] = round
    runtime[:test_evidence_runs] << verification
    verification
  end

  def finding_for_lens(verdict, scenario, lens)
    return "None" if verdict == "ready"
    return "RP-SEC-004 | blocker | rejected | unsupported" if scenario == :unresolved

    "#{lens == 'correctness' ? 'RP-COR-001' : 'RP-TST-002'} | blocker | open"
  end

  def repair_and_refresh_basis(task, scenario, runtime, output)
    if scenario == :repairable
      source = File.join(task.project_root, "lib", "value.rb")
      File.write(source, File.read(source).sub("41", "42"))
      regression = File.join(task.project_root, "test", "value_check.rb")
      File.write(regression, <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/value"

        class ValueTest < Minitest::Test
          def test_answer
            assert_equal 42, PanelValue.answer
          end
        end
      RUBY
    end
    state = capture_repository_state(task, "stages.panel.revise")
    runtime[:cycle] += 1
    bind_runtime_basis(runtime, state)
    ledger = if scenario == :repairable
               "RP-COR-001=resolved|repair=lib/value.rb|verification=test/value_check.rb; " \
                 "RP-TST-002=resolved|repair=test/value_check.rb|verification=passed"
             else
               "RP-SEC-004=rejected|evidence=unsupported|status=unresolved"
             end
    write_complete(output, <<~MD.chomp)
      Workflow-Status: reviewing
      Comparison-Base: #{runtime[:comparison_base] || "none"}
      Basis-Digest: #{runtime.fetch(:basis)}
      Repository-Fingerprint: #{state.fetch("fingerprint")}
      Finding-Ledger: #{ledger}
      Repository-State: #{JSON.generate(state)}
    MD
  end

  def build_readiness(task, scenario, runtime)
    if scenario == :inconclusive
      return [
        "Outcome: inconclusive",
        "Basis-Digest: #{runtime.fetch(:basis)}",
        "Terminal-Repository-Fingerprint: #{runtime.fetch(:fingerprint)}",
        "Comparison-Base: #{runtime[:comparison_base] || 'none'}",
        "Original-Change-State: working-change",
        "Required-Verification: not-passed",
        "Analytical-Only: true",
        "Human-Approval: false",
        "Owner-Authority: sole-owner",
        "Refs-Unchanged: true",
        "Terminal-Verification-Status: not-run",
        "Required-Environment-Unavailable: true"
      ].join("\n")
    end

    state = capture_repository_state(task, "stages.readiness")
    reviewed = runtime.fetch(:review_records).last&.fetch(:fingerprint) || runtime.fetch(:fingerprint)
    stale = state.fetch("fingerprint") != reviewed
    terminal_verification = nil
    if !stale && %i[repairable committed_change].include?(scenario)
      terminal_verification = run_repository_verification(task, "stages.readiness")
      runtime[:readiness_runs] << terminal_verification
      state = capture_repository_state(task, "stages.readiness")
      stale ||= terminal_verification.fetch("pre_fingerprint") != terminal_verification.fetch("post_fingerprint")
    end
    verification_failed = terminal_verification && terminal_verification.fetch("status") != "passed"
    outcome = if stale
                "state-stale"
              elsif scenario == :unresolved || verification_failed
                "changes-requested"
              else
                "ready"
              end
    lines = [
      "Outcome: #{outcome}",
      "Basis-Digest: #{runtime.fetch(:basis)}",
      "Terminal-Repository-Fingerprint: #{state.fetch('fingerprint')}",
      "Comparison-Base: #{runtime[:comparison_base] || 'none'}",
      "Original-Change-State: #{scenario == :committed_change ? 'committed' : 'working-change'}",
      "Required-Verification: #{outcome == 'ready' ? 'passed' : 'not-passed'}",
      "Analytical-Only: true",
      "Human-Approval: false",
      "Owner-Authority: sole-owner",
      "Refs-Unchanged: true"
    ]
    if terminal_verification
      lines << "Terminal-Verification-Command: #{terminal_verification.fetch('command')}"
      lines << "Terminal-Verification-Status: #{terminal_verification.fetch('status')}"
      lines << "Terminal-Verification-Pre-Fingerprint: #{terminal_verification.fetch('pre_fingerprint')}"
      lines << "Terminal-Verification-Post-Fingerprint: #{terminal_verification.fetch('post_fingerprint')}"
    else
      lines << "Terminal-Verification-Status: not-run"
    end
    lines << "Workflow-Repair-Uncommitted: true" if scenario == :repairable
    if scenario == :unresolved
      lines.concat([
        "Unresolved-Blocking: RP-SEC-004", "Disposition: rejected",
        "Rejection-Evidence: unsupported", "Repair-Round-Cap: reached"
      ])
    end
    if stale
      lines << "Drift-Source: #{scenario == :test_evidence_stale ? 'test-evidence' : 'between-review'}"
      lines << "Repair-Absorbed-Drift: false"
    end
    lines.join("\n")
  end

  def bind_runtime_basis(runtime, state)
    runtime[:fingerprint] = state.fetch("fingerprint")
    runtime[:basis] = "sha256:#{Digest::SHA256.hexdigest([state.fetch('fingerprint'), runtime[:comparison_base], runtime.fetch(:cycle)].join("\0"))}"
  end

  def basis_fields(body)
    %w[Basis-Digest Repository-Fingerprint].to_h do |field|
      [field, body[/^#{Regexp.escape(field)}: (.+)$/, 1] || raise("missing #{field}")]
    end
  end

  def write_complete(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{body}\n\n<!-- COMPLETE -->\n")
  end

  def capture_repository_state(task, slot)
    @repository_state_slots << slot
    tool = task.managed_runtime_context(slot).fetch(:tools).find { |path| File.basename(path) == "repository-state.rb" }
    stdout, stderr, status = Open3.capture3(tool, chdir: task.folder)
    raise "repository-state failed: #{stderr} #{stdout}" unless status.success?
    JSON.parse(stdout)
  end

  def run_repository_verification(task, slot)
    pre = capture_repository_state(task, slot).fetch("fingerprint")
    tests = Dir.glob(File.join(task.project_root, "test", "*_check.rb")).sort
    raise "fixture has no declared Ruby tests" if tests.empty?

    commands = []
    passed = tests.all? do |path|
      relative = path.delete_prefix("#{task.project_root}/")
      commands << "ruby #{relative}"
      _stdout, _stderr, status = Open3.capture3(RbConfig.ruby, relative, chdir: task.project_root)
      status.success?
    end
    post = capture_repository_state(task, slot).fetch("fingerprint")
    {
      "command" => commands.join(" && "), "status" => passed ? "passed" : "failed",
      "pre_fingerprint" => pre, "post_fingerprint" => post
    }
  end

  def target_fingerprint(task_path)
    task = Hive::Task.new(task_path)
    capture_repository_state(task, "stages.basis").fetch("fingerprint")
  end

  def target_authority(project)
    {
      "head" => git!(project, "rev-parse", "HEAD").strip,
      "symbolic_head" => git!(project, "symbolic-ref", "-q", "HEAD").strip,
      "refs" => git!(project, "for-each-ref", "--format=%(refname)%09%(objectname)", "refs")
    }
  end

  def executable_agents(workflow)
    workflow.stages.each_with_object({}) do |stage, actors|
      next unless %i[agent council].include?(stage.kind)
      prefix = "stages.#{stage.name}"
      actors[prefix] = stage.agent
      Array(stage.reviewers).each { |reviewer| actors["#{prefix}.reviewers.#{reviewer.name}"] = reviewer.agent }
      actors["#{prefix}.revise"] = stage.council.revise.agent if stage.council&.revise
    end
  end

  def assert_test_passes(project, test_path)
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, test_path, chdir: project)
    assert status.success?, stderr
  end

  def build_registry(path)
    FileUtils.mkdir_p(path)
    git!(path, "init", "-q", "-b", "main")
    git!(path, "config", "user.email", "reviewer-panel@example.test")
    git!(path, "config", "user.name", "Reviewer Panel fixture")
    destination = File.join(path, "packages", PACKAGE_NAME, PACKAGE_VERSION)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp_r(PACKAGE_ROOT, destination)
    FileUtils.rm_f(File.join(destination, "manifest.yml"))
    git!(path, "add", "packages")
    git!(path, "commit", "-qm", "ephemeral behavior source")
    source_revision = git!(path, "rev-parse", "HEAD").strip

    package = HoneycombRegistry::Package.new(destination, root: path)
    File.write(package.manifest_path, YAML.dump(manifest_metadata(source_revision)))
    result = HoneycombRegistry::Manifest.generate(package)
    raise result.findings.to_h.inspect if result.findings.errors?
    git!(path, "add", "packages")
    git!(path, "commit", "-qm", "ephemeral canonical manifest")
    review_head = git!(path, "rev-parse", "HEAD").strip
    catalog = {"schema" => "honeycomb-catalog/v2", "entries" => [catalog_entry(result.document, source_revision, review_head)]}
    File.binwrite(File.join(path, "catalog.json"), HoneycombRegistry::CanonicalJSON.dump(catalog))
    git!(path, "add", "catalog.json")
    git!(path, "commit", "-qm", "ephemeral catalog")
    path
  end

  def manifest_metadata(source_revision)
    {
      "schema" => "honeycomb-manifest/v1", "name" => PACKAGE_NAME, "version" => PACKAGE_VERSION,
      "description" => "Deterministic Reviewer Panel execution fixture",
      "author" => {"name" => "Honeycomb maintainers", "url" => "https://example.test/honeycomb"},
      "license" => "MIT", "hive_min_version" => "0.6.0",
      "source" => {"url" => "https://example.test/honeycomb/commit/#{source_revision}", "revision" => source_revision},
      "x-hive" => {
        "tools" => [{"path" => "tools/repository-state.rb"}],
        "prompt_assets" => [{"path" => "assets/evidence-contract.md"}], "optional_inputs" => []
      },
      "x-security" => {"network_host_reasons" => {}, "suppressions" => []}
    }
  end

  def catalog_entry(manifest, source_revision, review_head)
    permissions = manifest.fetch("permissions")
    {
      "name" => PACKAGE_NAME, "version" => PACKAGE_VERSION, "latest_version" => PACKAGE_VERSION,
      "description" => manifest.fetch("description"), "release_tier" => "community", "current_tier" => "community",
      "permission_risk" => permissions.fetch("risk"), "state" => "listed", "discoverable" => true,
      "exact_resolution" => "allowed", "verification" => nil, "history" => [], "advisories" => [],
      "author" => manifest.fetch("author"), "license" => manifest.fetch("license"),
      "hive_min_version" => manifest.fetch("hive_min_version"), "permissions" => permissions,
      "install_command" => "hive workflow install honeycomb/#{PACKAGE_NAME}",
      "package_url" => "https://example.test/packages/#{PACKAGE_NAME}/#{PACKAGE_VERSION}",
      "reviews_url" => "https://example.test/reviews/#{PACKAGE_NAME}/#{PACKAGE_VERSION}",
      "community_reviews_url" => nil, "source_sha" => source_revision,
      "listing_approval" => {
        "release_sha256" => manifest.fetch("release_sha256"), "head_sha" => review_head,
        "lint_checked_at" => "2026-07-20T00:00:00Z", "approved_by" => ["fixture-owner"],
        "approved_at" => "2026-07-20T00:00:01Z",
        "reviews" => [{
          "reviewer" => "fixture-owner", "reviewed_at" => "2026-07-20T00:00:01Z",
          "review_url" => "https://example.test/reviews/reviewer-panel/fixture-owner",
          "evidence_digest" => Digest::SHA256.hexdigest("reviewer-panel:fixture-owner")
        }]
      }
    }
  end

  def git!(repository, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", repository, *arguments)
    raise "git #{arguments.join(' ')} failed: #{stderr}" unless status.success?
    stdout
  end

  def git_success?(repository, *arguments)
    _stdout, _stderr, status = Open3.capture3("git", "-C", repository, *arguments)
    status.success?
  end

  def with_environment(overrides)
    before = overrides.to_h { |key, _| [key, ENV.key?(key) ? ENV[key] : :__missing__] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    before&.each { |key, value| value == :__missing__ ? ENV.delete(key) : ENV[key] = value }
  end
end
