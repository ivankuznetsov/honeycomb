# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "json"
require "yaml"

ROOT_CAUSE_HIVE_REVISION = "af22485f9b2bee27a7497dc138e5e58ab9725bde"
root_cause_hive_source = ENV["HONEYCOMB_HIVE_SOURCE"].to_s
ROOT_CAUSE_HIVE_PRECHECK_ERROR = begin
  if root_cause_hive_source.empty?
    "HONEYCOMB_HIVE_SOURCE must name the pinned Hive checkout"
  elsif !File.directory?(File.join(root_cause_hive_source, "lib"))
    "HONEYCOMB_HIVE_SOURCE does not contain Hive lib/"
  else
    head, head_error, head_status = Open3.capture3("git", "-C", root_cause_hive_source, "rev-parse", "HEAD")
    dirty, dirty_error, dirty_status = Open3.capture3(
      "git", "-C", root_cause_hive_source, "status", "--porcelain=v1", "--untracked-files=all"
    )
    flags, flags_error, flags_status = Open3.capture3(
      "git", "-C", root_cause_hive_source, "ls-files", "-v", "-f", "-z"
    )
    hidden_flag = flags.split("\0").find { |entry| !entry.empty? && entry.getbyte(0) != "H".ord }
    if !head_status.success?
      "cannot read Hive revision: #{head_error.strip}"
    elsif head.strip != ROOT_CAUSE_HIVE_REVISION
      "Hive revision #{head.strip.inspect} is not #{ROOT_CAUSE_HIVE_REVISION}"
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

$LOAD_PATH.unshift(File.join(root_cause_hive_source, "lib")) if ROOT_CAUSE_HIVE_PRECHECK_ERROR.nil?
ROOT_CAUSE_HIVE_LOAD_ERROR = begin
  if ROOT_CAUSE_HIVE_PRECHECK_ERROR.nil?
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

class RootCauseRepairHiveExecutionTest < Minitest::Test
  PACKAGE_NAME = "root-cause-repair"
  PACKAGE_VERSION = "1.0.0"
  PACKAGE_ROOT = File.join(ROOT, "packages", PACKAGE_NAME, PACKAGE_VERSION)
  MAPPING_SLOTS = %w[
    stages.reproduce
    stages.diagnose
    stages.repair
    stages.verification
    stages.verification.reviewers.causal-verifier
    stages.verification.revise
    stages.certificate
  ].freeze

  def setup
    assert_nil ROOT_CAUSE_HIVE_PRECHECK_ERROR, ROOT_CAUSE_HIVE_PRECHECK_ERROR
    assert_nil ROOT_CAUSE_HIVE_LOAD_ERROR,
               "pinned Hive could not be loaded: #{ROOT_CAUSE_HIVE_LOAD_ERROR&.message}"
    @repository_state_slots = []
  end

  def test_install_requires_escalation_and_pins_one_agent_mapping_and_tool
    with_sandbox("verified") do |registry, project|
      client = Hive::WorkflowPackage::RegistryClient.new(repository: registry)
      error = assert_raises(Hive::Commands::Workflow::ConsentRequired) do
        install(client, project, allow_escalation: false)
      end
      assert_match(/unbounded\/high-risk.*--allow-escalation/i, error.message)
      store = Hive::WorkflowPackage::ManagedStore.new(File.join(project, ".hive-state"))
      assert_nil store.selected(PACKAGE_NAME, cfg: Hive::Config.load(project)),
                 "denied escalation must not activate the package"

      payload = install(client, project, allow_escalation: true)
      assert_equal "installed", payload.fetch("status")
      assert_equal "high", payload.dig("permissions", "risk")
      assert_equal MAPPING_SLOTS.sort, payload.fetch("mappings").map { |mapping| mapping.fetch("slot") }
      assert payload.fetch("mappings").all? { |mapping| mapping.fetch("agent") == "codex" }

      task_path = create_task(project, "install-proof")
      task = Hive::Task.new(task_path)
      assert_equal payload.fetch("catalog_commit"), task.workflow_commit
      assert_equal payload.fetch("manifest_digest"), task.workflow_manifest_digest
      assert_equal payload.fetch("configuration_digest"), task.workflow_configuration_digest
      assert_equal PACKAGE_NAME.to_sym, task.workflow.id

      context = task.managed_runtime_context("stages.reproduce")
      tool = context.fetch(:tools).find { |path| File.basename(path) == "repository-state.rb" }
      assert File.executable?(tool), "installed repository-state tool must retain mode 100755"
      state = capture_repository_state(task, "stages.reproduce")
      assert_equal "honeycomb-repository-state/v1", state.fetch("schema")
      assert_equal "ok", state.fetch("status")

      configured_agents = executable_agents(task.workflow)
      assert_equal MAPPING_SLOTS, configured_agents.keys
      assert_equal ["codex"], configured_agents.values.uniq
      certificate_prompt = File.read(File.join(PACKAGE_ROOT, "instructions", "certificate.md"))
      assert_match(/owner authority|owner-controlled/i, certificate_prompt)
      %w[commit push release deploy].each { |operation| assert_match(/Never[\s\S]*\b#{operation}\b/i, certificate_prompt) }
    end
  end

  def test_native_engines_revise_a_symptom_patch_then_verify_and_resume_idempotently
    with_installed_task("verified", "causal-revision") do |project, path, payload|
      authority = target_authority(project)
      runtime = {review_calls: 0, revise_calls: 0}
      final_path = with_deterministic_agents(:causal_revision, runtime) do
        run_workflow(project, path)
      end

      certificate = File.read(File.join(final_path, "repair-certificate.md"))
      assert_match(/\AOutcome: verified\n/, certificate)
      assert_equal 2, runtime.fetch(:review_calls)
      assert_equal 1, runtime.fetch(:revise_calls)
      assert_includes File.read(File.join(project, "lib", "value.rb")), "42"
      assert_includes File.read(File.join(project, "test", "value_check.rb")), "assert_equal 42"
      assert_test_passes(project)
      assert_equal authority, target_authority(project)
      assert_match(/lib\/value.rb/, git!(project, "status", "--short"))

      verification_path = move_task_to_stage(project, final_path, "verification")
      before = runtime.dup
      result = with_deterministic_agents(:causal_revision, runtime) do
        Hive::Stages::Council.run!(Hive::Task.new(verification_path), {})
      end
      assert_equal :complete, result.fetch(:status)
      assert_equal before, runtime, "completed council resume must not spawn reviewers or revisers"
      assert_equal 2, Dir.glob(File.join(verification_path, "reviews", "causal-verifier-*.md")).length
      assert_equal authority, target_authority(project)
      assert_equal payload.fetch("catalog_commit"), Hive::Task.new(verification_path).workflow_commit
    end
  end

  def test_terminal_no_op_and_drift_scenarios_preserve_target_refs
    {
      "not-reproduced" => [:not_reproduced, "not-reproduced"],
      "blocked" => [:blocked, "blocked"],
      "verified" => [:drift, "blocked"]
    }.each do |fixture, (scenario, outcome)|
      with_installed_task(fixture, scenario.to_s) do |project, path, _payload|
        authority = target_authority(project)
        baseline = target_fingerprint(path)
        mutation = if scenario == :drift
                     lambda do |stage_name|
                       File.write(File.join(project, "unexpected-owner-file.txt"), "owner change\n") if stage_name == "diagnose"
                     end
                   end
        final_path = with_deterministic_agents(scenario, {}) do
          run_workflow(project, path, before_stage: mutation)
        end
        certificate = File.read(File.join(final_path, "repair-certificate.md"))
        assert_match(/\AOutcome: #{Regexp.escape(outcome)}\n/, certificate, scenario)
        assert_includes certificate, "Manual-Only: true" if scenario == :blocked
        assert_equal authority, target_authority(project), scenario

        terminal = target_fingerprint(final_path)
        if scenario == :not_reproduced || scenario == :blocked
          assert_equal baseline, terminal, scenario
          assert_empty git!(project, "status", "--porcelain=v1"), scenario
          refute_includes certificate, "Terminal-Repository-State:", scenario
          refute_includes @repository_state_slots, "stages.certificate", scenario
        else
          refute_equal baseline, terminal
          assert_match(/unexpected-owner-file\.txt/, git!(project, "status", "--short"))
        end
      end
    end
  end

  def test_native_council_cap_exhaustion_cannot_become_verified
    with_installed_task("verified", "cap") do |project, path, _payload|
      authority = target_authority(project)
      runtime = {review_calls: 0, revise_calls: 0}
      final_path = with_deterministic_agents(:cap, runtime) { run_workflow(project, path) }

      certificate = File.read(File.join(final_path, "repair-certificate.md"))
      assert_match(/\AOutcome: blocked\n/, certificate)
      refute_match(/\AOutcome: verified$/m, certificate)
      assert_equal 3, runtime.fetch(:review_calls)
      assert_equal 2, runtime.fetch(:revise_calls)
      marker = Hive::Markers.current(File.join(final_path, "verification.md"))
      assert_equal :complete, marker.name
      assert_equal "max_rounds", marker.attrs.fetch("reason")
      assert_equal 3, marker.attrs.fetch("round").to_i
      assert_equal authority, target_authority(project)
      refute_includes File.read(File.join(project, "lib", "value.rb")), "42"
      assert_includes File.read(File.join(project, "test", "value_check.rb")), "assert_equal 41"
    end
  end

  private

  def with_installed_task(fixture, slug)
    with_sandbox(fixture) do |registry, project|
      client = Hive::WorkflowPackage::RegistryClient.new(repository: registry)
      payload = install(client, project, allow_escalation: true)
      yield project, create_task(project, slug.tr("_", "-")), payload
    end
  end

  def with_sandbox(fixture)
    sandbox = Dir.mktmpdir("honeycomb-root-cause-hive")
    registry = build_registry(File.join(sandbox, "registry"))
    home = File.join(sandbox, "hive-home")
    FileUtils.mkdir_p(home)
    File.write(File.join(home, "config.yml"), {"registered_projects" => []}.to_yaml)
    with_environment("HIVE_HOME" => home) do
      project = build_project(File.join(sandbox, "#{fixture}-project"), fixture)
      yield registry, project
    end
  ensure
    FileUtils.chmod_R(0o700, sandbox) if sandbox && File.exist?(sandbox)
    FileUtils.rm_rf(sandbox) if sandbox
    Hive::Workflows::Project.reset! if defined?(Hive::Workflows::Project)
  end

  def build_project(path, fixture)
    FileUtils.mkdir_p(path)
    FileUtils.cp_r(File.join(fixture_path("managed-repair", "root-cause", "repos", fixture), "."), path)
    git!(path, "init", "-q", "-b", "main")
    git!(path, "config", "user.email", "root-cause@example.test")
    git!(path, "config", "user.name", "Root Cause fixture")
    git!(path, "add", ".")
    git!(path, "commit", "-qm", "seed target")

    state = File.join(path, ".hive-state")
    FileUtils.mkdir_p(File.join(state, "stages"))
    FileUtils.mkdir_p(File.join(state, "logs"))
    File.write(File.join(state, "config.yml"), Hive::Config::DEFAULTS.merge("hive_state_path" => ".hive-state").to_yaml)
    git!(state, "init", "-q", "-b", "hive-state")
    git!(state, "config", "user.email", "root-cause@example.test")
    git!(state, "config", "user.name", "Root Cause fixture")
    git!(state, "add", ".")
    git!(state, "commit", "-qm", "bootstrap fixture state")
    Hive::Config.register_project(name: File.basename(path), path: path, repository_identity: nil)
    path
  end

  def install(client, project, allow_escalation:)
    overrides = MAPPING_SLOTS.map { |slot| "#{slot}=codex" }
    Hive::Commands::Workflow::Install.new(
      "honeycomb/#{PACKAGE_NAME}@#{PACKAGE_VERSION}", project_root: project,
      json: true, yes: true, allow_escalation: allow_escalation,
      mapping_overrides: overrides, input_bindings: [], stdout: StringIO.new,
      registry_client: client, committer: ->(*) { }
    ).call!
  end

  def create_task(project, slug)
    capture_io do
      Hive::Commands::New.new(
        File.basename(project), "Repair the seeded defect", slug_override: slug,
        body_override: "The answer must be 42; preserve owner authority.", workflow: PACKAGE_NAME
      ).call!
    end
    File.join(project, ".hive-state", "stages", "1-inbox", slug)
  end

  def run_workflow(project, initial_path, before_stage: nil)
    path = initial_path
    workflow = Hive::Task.new(path).workflow
    workflow.stages.drop(1).each do |stage|
      before_stage&.call(stage.name)
      path = move_task_to_stage(project, path, stage.name)
      task = Hive::Task.new(path)
      result = stage.kind == :council ? Hive::Stages::Council.run!(task, {}) : Hive::Stages::Agent.run!(task, {})
      assert_equal :complete, result.fetch(:status), stage.name
    end
    path
  end

  def move_task_to_stage(project, current_path, stage_name)
    workflow = Hive::Task.new(current_path).workflow
    stage = workflow.stage_named(stage_name)
    destination_parent = File.join(project, ".hive-state", "stages", stage.dir)
    FileUtils.mkdir_p(destination_parent)
    destination = File.join(destination_parent, File.basename(current_path))
    return current_path if File.expand_path(current_path) == File.expand_path(destination)

    FileUtils.mv(current_path, destination)
    destination
  end

  def with_deterministic_agents(scenario, runtime)
    runtime[:review_calls] ||= 0
    runtime[:revise_calls] ||= 0
    original = Hive::Stages::Base.method(:spawn_agent)
    owner = self
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |task, **kwargs|
      owner.send(:deterministic_spawn, scenario, runtime, task, **kwargs)
    end
    yield
  ensure
    Hive::Stages::Base.define_singleton_method(:spawn_agent, original) if original
  end

  def deterministic_spawn(scenario, runtime, task, prompt:, cwd:, log_label:, expected_output: nil, **_kwargs)
    if expected_output
      if log_label.end_with?("-revise")
        runtime[:revise_calls] += 1
        revise_target(task.project_root, scenario)
        write_complete(expected_output, repair_body(task, scenario, revised: true))
      else
        runtime[:review_calls] += 1
        verdict = if scenario == :cap || (scenario == :causal_revision && runtime[:review_calls] == 1)
                    "changes_requested"
                  else
                    "ready"
                  end
        FileUtils.mkdir_p(File.dirname(expected_output))
        File.write(expected_output, <<~MD)
          Verdict: #{verdict}

          ## Findings
          #{verdict == "ready" ? "Causal repair verified." : "The symptom-only patch leaves the cause unchanged."}

          ## Required edits
          #{verdict == "ready" ? "None." : "Restore the test and repair lib/value.rb."}
        MD
      end
      return {status: :ok}
    end

    body = case log_label
           when "reproduce" then reproduce_body(task, scenario, runtime)
           when "diagnose" then diagnose_body(task, scenario, runtime)
           when "repair" then repair_body(task, scenario)
           when "certificate" then certificate_body(task, scenario, runtime)
           else raise "unexpected deterministic stage #{log_label}"
           end
    write_complete(File.join(cwd, task.workflow.stage_named(log_label).state_file), body)
    {status: :ok}
  end

  def reproduce_body(task, scenario, runtime)
    state = capture_repository_state(task, "stages.reproduce")
    runtime[:baseline_fingerprint] = state.fetch("fingerprint")
    case scenario
    when :not_reproduced
      "Workflow-Status: not-reproduced\nCommand: ruby test/value_check.rb\nResult: passed\nRepository-State: #{JSON.generate(state)}"
    when :blocked
      "Workflow-Status: blocked\nBlocker: owner-controlled external service unavailable\nRepository-State: #{JSON.generate(state)}"
    else
      _out, _err, status = Open3.capture3(RbConfig.ruby, "test/value_check.rb", chdir: task.project_root)
      raise "seeded defect unexpectedly passed" if status.success?
      "Workflow-Status: continue\nFocused-Regression-Before: failed\nRepository-State: #{JSON.generate(state)}"
    end
  end

  def diagnose_body(task, scenario, runtime)
    upstream = propagated_status(task.folder)
    return "Workflow-Status: #{upstream}\nDiagnosis intentionally skipped." if upstream

    state = capture_repository_state(task, "stages.diagnose")
    if scenario == :drift && state.fetch("fingerprint") != runtime.fetch(:baseline_fingerprint)
      return "Workflow-Status: blocked\nBlocker: unexpected repository-state drift\nRepository-State: #{JSON.generate(state)}"
    end
    "Workflow-Status: continue\nCause: FixtureValue.answer returns 41 rather than 42.\nRepository-State: #{JSON.generate(state)}"
  end

  def repair_body(task, scenario, revised: false)
    upstream = propagated_status(task.folder)
    return "Workflow-Status: #{upstream}\nRepair intentionally skipped." if upstream

    unless revised
      if scenario == :causal_revision || scenario == :cap
        weaken_fixture_test(task.project_root)
      else
        repair_fixture_source(task.project_root)
      end
    end
    state = capture_repository_state(task, revised ? "stages.verification.revise" : "stages.repair")
    "Workflow-Status: continue\nRepair-Attempted: true\nRepository-State: #{JSON.generate(state)}"
  end

  def certificate_body(task, scenario, runtime)
    upstream = propagated_status(task.folder)
    if %w[not-reproduced blocked].include?(upstream)
      return <<~MD.chomp
        Outcome: #{upstream}
        Focused-Regression-Before: not-run
        Focused-Regression-After: not-run
        Causal-Consensus: ready
        Council-Rounds: #{runtime.fetch(:review_calls, 0)}
        #{"Manual-Only: true" if upstream == "blocked"}
        Refs-Unchanged: true
        Propagated-Workflow-Status: #{upstream}
      MD
    end

    outcome = scenario == :cap ? "blocked" : "verified"
    state = capture_repository_state(task, "stages.certificate")
    <<~MD.chomp
      Outcome: #{outcome}
      Focused-Regression-Before: #{outcome == "verified" ? "failed" : "not-run"}
      Focused-Regression-After: #{outcome == "verified" ? "passed" : "not-run"}
      Causal-Consensus: #{scenario == :cap ? "unresolved" : "ready"}
      Council-Rounds: #{runtime.fetch(:review_calls, 0)}
      #{"Manual-Only: true" if scenario == :blocked}
      Refs-Unchanged: true
      Terminal-Repository-State: #{JSON.generate(state)}
    MD
  end

  def propagated_status(folder)
    Dir.glob(File.join(folder, "*.md")).sort.each do |path|
      status = File.read(path)[/^Workflow-Status: (not-reproduced|blocked)$/, 1]
      return status if status
    end
    nil
  end

  def write_complete(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{body}\n\n<!-- COMPLETE -->\n")
  end

  def repair_fixture_source(project)
    path = File.join(project, "lib", "value.rb")
    File.write(path, File.read(path).sub("41", "42"))
  end

  def weaken_fixture_test(project)
    path = File.join(project, "test", "value_check.rb")
    File.write(path, File.read(path).sub("assert_equal 42", "assert_equal 41"))
  end

  def revise_target(project, scenario)
    return weaken_fixture_test(project) if scenario == :cap

    test_path = File.join(project, "test", "value_check.rb")
    File.write(test_path, File.read(test_path).sub("assert_equal 41", "assert_equal 42"))
    repair_fixture_source(project)
  end

  def capture_repository_state(task, slot)
    @repository_state_slots << slot
    tool = task.managed_runtime_context(slot).fetch(:tools).find { |path| File.basename(path) == "repository-state.rb" }
    stdout, stderr, status = Open3.capture3(tool, chdir: task.folder)
    raise "repository-state failed: #{stderr} #{stdout}" unless status.success?

    JSON.parse(stdout)
  end

  def target_fingerprint(task_path)
    task = Hive::Task.new(task_path)
    capture_repository_state(task, "stages.reproduce").fetch("fingerprint")
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

  def assert_test_passes(project)
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "test/value_check.rb", chdir: project)
    assert status.success?, stderr
  end

  def build_registry(path)
    FileUtils.mkdir_p(path)
    git!(path, "init", "-q", "-b", "main")
    git!(path, "config", "user.email", "root-cause@example.test")
    git!(path, "config", "user.name", "Root Cause fixture")
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
      "description" => "Deterministic root-cause repair execution fixture",
      "author" => {"name" => "Honeycomb maintainers", "url" => "https://example.test/honeycomb"},
      "license" => "MIT", "hive_min_version" => "0.6.0",
      "source" => {"url" => "https://example.test/honeycomb/commit/#{source_revision}", "revision" => source_revision},
      "x-hive" => {
        "tools" => [{"path" => "tools/repository-state.rb"}],
        "prompt_assets" => [{"path" => "assets/evidence-contract.md"}],
        "optional_inputs" => []
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
          "review_url" => "https://example.test/reviews/root-cause/fixture-owner",
          "evidence_digest" => Digest::SHA256.hexdigest("root-cause:fixture-owner")
        }]
      }
    }
  end

  def git!(repository, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", repository, *arguments)
    raise "git #{arguments.join(' ')} failed: #{stderr}" unless status.success?
    stdout
  end

  def with_environment(overrides)
    before = overrides.to_h { |key, _| [key, ENV.key?(key) ? ENV[key] : :__missing__] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    before&.each { |key, value| value == :__missing__ ? ENV.delete(key) : ENV[key] = value }
  end
end
