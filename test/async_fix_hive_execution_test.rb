# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/async_fix_registry"
require "digest"
require "json"
require "stringio"
require "yaml"

ASYNC_FIX_HIVE_REVISION = "ee7c8cefd7da8f814170e37df727ab02009b05c3"
async_fix_hive_source = ENV["HONEYCOMB_HIVE_SOURCE"].to_s
ASYNC_FIX_HIVE_PRECHECK_ERROR = begin
  if async_fix_hive_source.empty?
    "HONEYCOMB_HIVE_SOURCE must name the pinned Hive checkout"
  elsif !File.directory?(File.join(async_fix_hive_source, "lib"))
    "HONEYCOMB_HIVE_SOURCE does not contain Hive lib/"
  else
    head, head_error, head_status = Open3.capture3(
      "git", "-C", async_fix_hive_source, "rev-parse", "HEAD"
    )
    dirty, dirty_error, dirty_status = Open3.capture3(
      "git", "-C", async_fix_hive_source,
      "status", "--porcelain=v1", "--untracked-files=all"
    )
    flags, flags_error, flags_status = Open3.capture3(
      "git", "-C", async_fix_hive_source, "ls-files", "-v", "-f", "-z"
    )
    hidden_flag = flags.split("\0").find do |entry|
      !entry.empty? && entry.getbyte(0) != "H".ord
    end
    if !head_status.success?
      "cannot read Hive revision: #{head_error.strip}"
    elsif head.strip != ASYNC_FIX_HIVE_REVISION
      "Hive revision #{head.strip.inspect} is not #{ASYNC_FIX_HIVE_REVISION}"
    elsif !dirty_status.success?
      "cannot inspect Hive checkout: #{dirty_error.strip}"
    elsif !flags_status.success?
      "cannot inspect Hive index flags: #{flags_error.strip}"
    elsif hidden_flag
      "Hive checkout must not use non-default index flags; " \
        "found #{hidden_flag.byteslice(0, 1).inspect}"
    elsif !dirty.empty?
      "Hive checkout must be clean; status is #{dirty.lines.first.to_s.strip.inspect}"
    end
  end
end

$LOAD_PATH.unshift(File.join(async_fix_hive_source, "lib")) if ASYNC_FIX_HIVE_PRECHECK_ERROR.nil?
ASYNC_FIX_HIVE_LOAD_ERROR = begin
  if ASYNC_FIX_HIVE_PRECHECK_ERROR.nil?
    require "hive"
    require "hive/commands/new"
    require "hive/commands/workflow/install"
    require "hive/daemon/policy"
    require "hive/draft_pr_receipt"
    require "hive/gh"
    require "hive/markers"
    require "hive/stages/agent"
    require "hive/stages/agent_worktree"
    require "hive/task"
    require "hive/task_action"
    require "hive/workflow_package/managed_store"
    require "hive/workflow_package/registry_client"
  end
  nil
rescue LoadError => e
  e
end

class AsyncFixHiveExecutionTest < Minitest::Test
  include AsyncFixRegistrySupport

  SLOT = "stages.fix"
  PR_URL = "https://github.com/acme/widgets/pull/42"
  TEST_SECRET = "github_pat_#{'A' * 24}"

  def setup
    assert_nil ASYNC_FIX_HIVE_PRECHECK_ERROR, ASYNC_FIX_HIVE_PRECHECK_ERROR
    assert_nil ASYNC_FIX_HIVE_LOAD_ERROR,
               "pinned Hive could not be loaded: #{ASYNC_FIX_HIVE_LOAD_ERROR&.message}"
  end

  def test_real_install_requires_consent_pins_provenance_and_allows_agent_remapping
    with_execution_sandbox do |registry, project, runtime|
      managed_before = managed_workflow_fingerprint(project)
      error = assert_raises(Hive::Commands::Workflow::ConsentRequired) do
        install(registry, project, agent: "codex", allow_escalation: false)
      end
      assert_match(/unbounded\/high-risk.*--allow-escalation/i, error.message)
      assert_equal managed_before, managed_workflow_fingerprint(project),
                   "denied consent must leave no managed workflow state"

      payload = install(registry, project, agent: "codex", allow_escalation: true)
      assert_equal "installed", payload.fetch("status")
      assert_equal "high", payload.dig("permissions", "risk")
      assert_equal [SLOT], payload.fetch("mappings").map { |mapping| mapping.fetch("slot") }
      assert_equal "codex", payload.dig("mappings", 0, "agent")
      assert_equal "medium", payload.dig("mappings", 0, "effort")

      initial = create_task(project, "codex-mapping")
      task = move_to_fix(project, initial)
      assert_equal payload.fetch("source_commit"), task.workflow_commit
      assert_equal payload.fetch("manifest_digest"), task.workflow_manifest_digest
      assert_equal registry.source_revision, registry.manifest.dig("source", "revision")
      assert_equal payload.fetch("configuration_digest"), task.workflow_configuration_digest
      assert_equal "codex", task.workflow.stage_named("fix").agent
      assert_equal "medium", task.workflow.stage_named("fix").effort
      prompt_assets = task.managed_runtime_context(SLOT).fetch(:prompt_assets)
      assert_equal 1, prompt_assets.length
      assert_equal "fix-report-contract.md", File.basename(prompt_assets.first)
      assert_includes File.read(prompt_assets.first), "Decision: ready|no-fix|blocked"

      remapped = install(registry, project, agent: "claude", allow_escalation: true)
      assert_equal "claude", remapped.dig("mappings", 0, "agent")
      assert_equal "medium", remapped.dig("mappings", 0, "effort")
      remapped_task = move_to_fix(project, create_task(project, "claude-mapping"))
      assert_equal "claude", remapped_task.workflow.stage_named("fix").agent
      assert_equal "medium", remapped_task.workflow.stage_named("fix").effort
      refute_equal task.workflow_configuration_digest,
                   remapped_task.workflow_configuration_digest

      calls = []
      captured = []
      with_fake_remote(fake_remote(remapped_task, runtime), calls) do
        with_fake_agent(:direct, captured) do
          result = Hive::Stages::Agent.run!(remapped_task, {})
          assert_equal :complete, result.fetch(:status)
          assert_equal "pr-opened", result.fetch(:outcome)
        end
      end
      assert_equal 1, captured.length
      assert_equal :claude, captured.dig(0, :profile)
      assert_equal "medium", captured.dig(0, :effort)
      assert_equal 1, calls.count { |call| call.first == :push }
      assert_equal 1, calls.count { |call| call.first == :create }

      findings = HoneycombRegistry::Validator.validate(
        registry.package, require_hive: true
      )
      refute findings.errors?, findings.to_h.inspect
      assert_includes findings.codes, "hive.compatible"
    end
  end

  def test_direct_and_compact_plan_debug_paths_open_one_exact_draft_pr
    %i[direct debug].each do |scenario|
      with_installed_task("#{scenario}-fix") do |_registry, project, task, runtime|
        primary_before = checkout_fingerprint(project)
        calls = []
        captured = []
        remote = fake_remote(task, runtime)

        with_fake_remote(remote, calls) do
          with_fake_agent(scenario, captured) do
            result = Hive::Stages::Agent.run!(task, {})
            assert_equal :complete, result.fetch(:status), scenario
            assert_equal "pr-opened", result.fetch(:outcome), scenario
            assert_equal PR_URL, result.fetch(:pr_url), scenario

            again = Hive::Stages::Agent.run!(task, {})
            assert_equal "pr-opened", again.fetch(:outcome), scenario
          end
        end

        assert_equal 1, captured.length, "#{scenario} must use one reasoning/code actor"
        spawn = captured.fetch(0)
        assert_equal :codex, spawn.fetch(:profile)
        assert_equal "medium", spawn.fetch(:effort)
        refute_equal File.expand_path(project), File.expand_path(spawn.fetch(:cwd))
        assert_includes spawn.fetch(:prompt), "smallest cause-supported"
        assert_includes spawn.fetch(:prompt), "Declared package prompt assets"
        assert_equal 1, calls.count { |call| call.first == :push }
        assert_equal 1, calls.count { |call| call.first == :create }
        pushed = calls.find { |call| call.first == :push }
        receipt = read_receipt(task, runtime)
        assert_equal receipt.fetch("head_oid"), pushed.fetch(1)
        assert_equal task.slug, pushed.fetch(2)
        report = File.read(File.join(task.folder, "fix-report.md"))
        if scenario == :debug
          assert_includes report, "Compact plan:"
          assert_includes report, "Debug trace:"
        else
          refute_includes report, "Compact plan:"
          refute_includes report, "Debug trace:"
        end
        assert_equal primary_before, checkout_fingerprint(project), scenario
      end
    end
  end

  def test_no_fix_too_broad_and_auth_failure_never_publish
    {no_fix: "no-fix", blocked: "blocked"}.each do |scenario, expected|
      with_installed_task("#{scenario}-case") do |_registry, project, task, runtime|
        primary_before = checkout_fingerprint(project)
        calls = []
        captured = []
        remote = fake_remote(task, runtime)

        with_fake_remote(remote, calls) do
          with_fake_agent(scenario, captured) do
            result = Hive::Stages::Agent.run!(task, {})
            assert_equal expected, result.fetch(:outcome), scenario
            expected_status = scenario == :no_fix ? :complete : :error
            assert_equal expected_status, result.fetch(:status), scenario
          end
        end

        assert_equal 1, captured.length, scenario
        assert_empty calls.select { |call| %i[push create].include?(call.first) }, scenario
        assert_equal primary_before, checkout_fingerprint(project), scenario
      end
    end

    with_installed_task("auth-failure") do |_registry, project, task, runtime|
      primary_before = checkout_fingerprint(project)
      calls = []
      captured = []
      remote = fake_remote(task, runtime).merge(auth_error: true)

      with_fake_remote(remote, calls) do
        with_fake_agent(:direct, captured) do
          result = Hive::Stages::Agent.run!(task, {})
          assert_equal :error, result.fetch(:status)
          assert_equal "managed_agent_failed", result.fetch(:commit)
        end
      end

      assert_empty captured, "controller authentication must fail before agent work"
      assert_empty calls.select { |call| %i[push create].include?(call.first) }
      refute File.exist?(File.join(task.folder, "worktree.yml"))
      refute File.exist?(File.join(task.folder, "handoff.yml"))
      marker = Hive::Markers.current(File.join(task.folder, "fix-report.md"))
      assert_equal :error, marker.name
      assert_equal primary_before, checkout_fingerprint(project)
    end
  end

  def test_post_agent_auth_loss_preserves_manual_retry_and_resumes_without_respawn
    with_installed_task("post-agent-auth") do |_registry, _project, task, runtime|
      calls = []
      captured = []
      remote = fake_remote(task, runtime)
      remote[:auth_fail_after] = 1

      with_fake_remote(remote, calls) do
        with_fake_agent(:direct, captured) do
          first = Hive::Stages::Agent.run!(task, {})
          assert_equal :error, first.fetch(:status)
          assert_equal "blocked", first.fetch(:outcome)
          assert_equal "handoff_recoverable", first.fetch(:commit)
          assert_equal "agent_validated", read_receipt(task, runtime).fetch("phase")
          assert_recoverable_marker(task)
          assert_empty calls.select { |call| %i[push create].include?(call.first) }

          remote[:auth_fail_after] = nil
          resumed = Hive::Stages::Agent.run!(task, {})
          assert_equal :complete, resumed.fetch(:status)
          assert_equal "pr-opened", resumed.fetch(:outcome)
          assert_equal PR_URL, resumed.fetch(:pr_url)
        end
      end

      assert_equal 1, captured.length, "auth retry must not respawn the mapped agent"
      assert_equal 1, calls.count { |call| call.first == :push }
      assert_equal 1, calls.count { |call| call.first == :create }
    end
  end

  def test_push_and_create_failures_resume_by_exact_observation_without_duplicate_mutation
    %i[push create].each do |failure|
      with_installed_task("#{failure}-recovery") do |_registry, project, task, runtime|
        calls = []
        captured = []
        remote = fake_remote(task, runtime)
        remote[:push_observed] = false if failure == :push
        remote[:create_visible] = false if failure == :create

        with_fake_remote(remote, calls) do
          with_fake_agent(:direct, captured) do
            first = Hive::Stages::Agent.run!(task, {})
            assert_equal :error, first.fetch(:status), failure
            assert_equal "blocked", first.fetch(:outcome), failure
            receipt = read_receipt(task, runtime)
            expected_phase = failure == :push ? "push_intent" : "pr_create_intent"
            assert_equal expected_phase, receipt.fetch("phase"), failure
            assert_recoverable_marker(task)

            if failure == :push
              remote[:task_oid] = receipt.fetch("head_oid")
              remote[:push_observed] = true
            else
              remote[:prs] = [exact_pr(task, receipt.fetch("head_oid"), runtime.fetch(:base_oid))]
            end

            retry_call_offset = calls.length
            resumed = Hive::Stages::Agent.run!(task, {})
            assert_equal :complete, resumed.fetch(:status),
                         "#{failure}: result=#{resumed.inspect} " \
                         "receipt=#{read_receipt(task, runtime).inspect} " \
                         "calls=#{calls.inspect}"
            assert_equal "pr-opened", resumed.fetch(:outcome), failure
            assert_equal PR_URL, resumed.fetch(:pr_url), failure

            retry_calls = calls.drop(retry_call_offset)
            if failure == :push
              observed = retry_calls.index do |call|
                call.first == :remote_oid && call.fetch(1) == task.slug &&
                  call.fetch(2) == receipt.fetch("head_oid")
              end
              created = retry_calls.index { |call| call.first == :create }
              refute_nil observed, "push retry must observe the exact remote head"
              refute_nil created, "push retry must continue to one PR create"
              assert_operator observed, :<, created
              assert_empty retry_calls.select { |call| call.first == :push }
            else
              assert(retry_calls.any? do |call|
                call.first == :lookup && call.fetch(1) == task.slug && call.fetch(2) == 1
              end)
              assert_empty retry_calls.select { |call| %i[push create].include?(call.first) }
            end
          end
        end

        assert_equal 1, captured.length, "#{failure} retry must not respawn the agent"
        assert_equal 1, calls.count { |call| call.first == :push }, failure
        assert_equal 1, calls.count { |call| call.first == :create }, failure
        terminal = read_receipt(task, runtime)
        assert_equal "terminal", terminal.fetch("phase"), failure
        assert_equal terminal.fetch("head_oid"), terminal.fetch("observed_remote_oid"), failure
      end
    end
  end

  def test_secret_in_committed_output_is_quarantined_before_remote_mutation
    with_installed_task("secret-quarantine") do |_registry, _project, task, runtime|
      calls = []
      captured = []
      remote = fake_remote(task, runtime)
      result = nil

      with_fake_remote(remote, calls) do
        with_fake_agent(:secret, captured) do
          result = Hive::Stages::Agent.run!(task, {})
          assert_equal :error, result.fetch(:status)
          assert_equal "blocked", result.fetch(:outcome)
          assert_equal "quarantined", result.fetch(:commit)
        end
      end

      assert_equal 1, captured.length
      assert_empty calls.select { |call| %i[push create].include?(call.first) }
      marker = Hive::Markers.current(File.join(task.folder, "fix-report.md"))
      assert_equal :error, marker.name
      assert_equal "draft_pr_quarantined", marker.attrs.fetch("reason")
      receipt = read_receipt(task, runtime)
      assert_includes git!(receipt.fetch("worktree_path"), "show", "HEAD:credential.txt"),
                      TEST_SECRET
      refute File.exist?(File.join(task.folder, "pr.md"))
      refute_includes result.inspect, TEST_SECRET
      refute_includes marker.attrs.inspect, TEST_SECRET
      refute_includes receipt.inspect, TEST_SECRET
      refute_includes calls.inspect, TEST_SECRET
      controller_artifact_contents(task.folder).each do |path, contents|
        refute_includes contents, TEST_SECRET, path
      end
    end
  end

  def test_execution_leaves_both_source_checkouts_unchanged
    honeycomb_before = checkout_fingerprint(ROOT)
    hive_before = checkout_fingerprint(async_fix_hive_source)

    with_installed_task("source-checkouts") do |_registry, _project, task, runtime|
      with_fake_remote(fake_remote(task, runtime), []) do
        with_fake_agent(:direct, []) do
          result = Hive::Stages::Agent.run!(task, {})
          assert_equal "pr-opened", result.fetch(:outcome)
        end
      end
    end

    assert_equal honeycomb_before, checkout_fingerprint(ROOT)
    assert_equal hive_before, checkout_fingerprint(async_fix_hive_source)
  end

  private

  def async_fix_hive_source
    ENV.fetch("HONEYCOMB_HIVE_SOURCE")
  end

  def with_installed_task(slug)
    with_execution_sandbox do |registry, project, runtime|
      install(registry, project, agent: "codex", allow_escalation: true)
      task = move_to_fix(project, create_task(project, slug.tr("_", "-")))
      yield registry, project, task, runtime
    end
  end

  def with_execution_sandbox
    sandbox = Dir.mktmpdir("honeycomb-async-fix-hive")
    registry_root = File.join(sandbox, "registry")
    FileUtils.mkdir_p(registry_root)
    registry = build_async_fix_registry(registry_root)
    home = File.join(sandbox, "hive-home")
    FileUtils.mkdir_p(home)
    File.write(File.join(home, "config.yml"), {"registered_projects" => []}.to_yaml)
    deny_bin = File.join(sandbox, "deny-bin")
    write_default_deny_binaries(deny_bin)
    isolated_config = File.join(sandbox, "config")
    FileUtils.mkdir_p(isolated_config)
    sandbox_home = File.join(sandbox, "home")
    FileUtils.mkdir_p(sandbox_home)

    with_environment(
      "HIVE_HOME" => home,
      "HOME" => sandbox_home,
      "PATH" => "#{deny_bin}:#{ENV.fetch('PATH')}",
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => File::NULL,
      "GIT_CONFIG_SYSTEM" => nil,
      "GIT_TERMINAL_PROMPT" => "0",
      "GH_CONFIG_DIR" => File.join(isolated_config, "gh"),
      "XDG_CONFIG_HOME" => isolated_config,
      "GH_TOKEN" => nil,
      "GITHUB_TOKEN" => nil,
      "GH_ENTERPRISE_TOKEN" => nil,
      "GITHUB_ENTERPRISE_TOKEN" => nil,
      "OPENAI_API_KEY" => nil,
      "ANTHROPIC_API_KEY" => nil,
      "CLAUDE_CODE_OAUTH_TOKEN" => nil,
      "CODEX_API_KEY" => nil
    ) do
      project, runtime = build_project(File.join(sandbox, "target"), sandbox)
      yield registry, project, runtime
    end
  ensure
    Hive::Workflows::Project.reset! if defined?(Hive::Workflows::Project)
    FileUtils.chmod_R(0o700, sandbox) if sandbox && File.exist?(sandbox)
    FileUtils.rm_rf(sandbox) if sandbox
  end

  def build_project(path, sandbox)
    FileUtils.mkdir_p(File.join(path, "lib"))
    FileUtils.mkdir_p(File.join(path, "test"))
    File.write(File.join(path, ".gitignore"), ".hive-state/\n")
    File.write(File.join(path, "lib", "value.rb"), <<~RUBY)
      module FixtureValue
        def self.answer = 41
      end
    RUBY
    File.write(File.join(path, "test", "value_test.rb"), <<~RUBY)
      require "minitest/autorun"
      require_relative "../lib/value"

      class ValueTest < Minitest::Test
        def test_answer
          assert_equal 42, FixtureValue.answer
        end
      end
    RUBY
    git!(path, "init", "-q", "-b", "main")
    git!(path, "config", "user.email", "async-fix@example.test")
    git!(path, "config", "user.name", "Async Fix fixture")
    git!(path, "add", ".")
    git!(path, "commit", "-qm", "seed target defect")
    base_oid = git!(path, "rev-parse", "HEAD").strip

    origin = File.join(sandbox, "origin.git")
    git!(sandbox, "clone", "--bare", path, origin)
    git!(path, "remote", "add", "origin", origin)

    worktree_root = File.join(sandbox, "managed-worktrees")
    state = File.join(path, ".hive-state")
    FileUtils.mkdir_p(File.join(state, "stages"))
    FileUtils.mkdir_p(File.join(state, "logs"))
    File.write(
      File.join(state, "config.yml"),
      {
        "hive_state_path" => ".hive-state",
        "worktree_root" => worktree_root,
        "default_branch" => "main"
      }.to_yaml
    )
    git!(state, "init", "-q", "-b", "hive-state")
    git!(state, "config", "user.email", "async-fix@example.test")
    git!(state, "config", "user.name", "Async Fix fixture")
    git!(state, "add", ".")
    git!(state, "commit", "-qm", "bootstrap fixture state")
    Hive::Config.register_project(
      name: File.basename(path), path: path, repository_identity: nil
    )
    [
      path,
      {
        base_oid: base_oid,
        worktree_root: worktree_root,
        origin: origin,
        project: path
      }
    ]
  end

  def install(registry, project, agent:, allow_escalation:)
    client = Hive::WorkflowPackage::RegistryClient.new(repository: registry.root)
    Hive::Commands::Workflow::Install.new(
      "honeycomb/async-fix@0.0.0",
      project_root: project,
      json: true,
      yes: true,
      allow_escalation: allow_escalation,
      mapping_overrides: ["#{SLOT}=#{agent}"],
      input_bindings: [],
      stdout: StringIO.new,
      registry_client: client,
      committer: ->(*) { }
    ).call!
  end

  def create_task(project, slug)
    capture_io do
      Hive::Commands::New.new(
        File.basename(project),
        "Repair the seeded answer defect",
        slug_override: slug,
        body_override: "FixtureValue.answer should return 42 without broad refactoring.",
        base: "main",
        workflow: "async-fix"
      ).call!
    end
    File.join(project, ".hive-state", "stages", "1-inbox", slug)
  end

  def move_to_fix(project, initial_path)
    workflow = Hive::Task.new(initial_path).workflow
    fix = workflow.stage_named("fix")
    destination_parent = File.join(project, ".hive-state", "stages", fix.dir)
    FileUtils.mkdir_p(destination_parent)
    destination = File.join(destination_parent, File.basename(initial_path))
    FileUtils.mv(initial_path, destination)
    Hive::Task.new(destination)
  end

  def with_fake_agent(scenario, captured)
    owner = self
    spawn = lambda do |task, prompt:, cwd:, profile:, effort: nil,
                      runtime_policy: nil, **_kwargs|
      owner.send(:assert_agent_prompt!, prompt)
      captured << {
        prompt: prompt,
        cwd: cwd,
        profile: profile.name,
        effort: effort,
        environment: runtime_policy&.environment
      }
      owner.send(:perform_agent, scenario, task, cwd)
    end
    with_singleton_replacements([[Hive::Stages::Base, :spawn_agent, spawn]]) { yield }
  end

  def perform_agent(scenario, task, worktree)
    case scenario
    when :direct, :debug
      value = File.join(worktree, "lib", "value.rb")
      File.write(value, File.read(value).sub("41", "42"))
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "test/value_test.rb", chdir: worktree
      )
      raise "focused regression failed: #{stderr}" unless status.success?
      git!(worktree, "add", "lib/value.rb")
      git!(worktree, "commit", "-qm", "fix fixture answer")
    when :secret
      File.write(File.join(worktree, "credential.txt"), "#{TEST_SECRET}\n")
      git!(worktree, "add", "credential.txt")
      git!(worktree, "commit", "-qm", "capture unsafe fixture")
    when :no_fix, :blocked
      nil
    else
      raise "unknown fake-agent scenario #{scenario.inspect}"
    end

    File.write(File.join(task.folder, "fix-report.md"), report_for(scenario))
    {status: :ok, exit_code: 0}
  end

  def report_for(scenario)
    decision = case scenario
               when :no_fix then "no-fix"
               when :blocked then "blocked"
               else "ready"
               end
    body = <<~REPORT
      Decision: #{decision}

      Reproduction:
      The focused fixture demonstrated that the answer was 41 instead of 42.

      Cause:
      #{scenario == :blocked ? 'The requested work expanded beyond a bounded repair.' : 'The fixture returned the stale literal 41.'}

      Changes:
      #{report_changes(scenario)}

      Tests:
      #{scenario == :blocked ? 'Not run because the scope boundary was reached.' : 'ruby test/value_test.rb (pass or not applicable)'}

      Risks:
      The deterministic fixture does not contact external services.

      Suggested PR title: Repair fixture answer
    REPORT
    if scenario == :debug
      body << <<~REPORT

        Compact plan:
        Inspect the literal, patch it, then run the focused regression.

        Debug trace:
        The failing assertion isolated the stale return value as the cause.
      REPORT
    end
    body
  end

  def report_changes(scenario)
    case scenario
    when :no_fix then "No repository change was warranted."
    when :blocked then "No change was made because the task was too broad."
    when :secret then "Added the unsafe fixture so Hive can prove quarantine."
    else "Changed lib/value.rb from 41 to 42."
    end
  end

  def fake_remote(task, runtime)
    {
      base_oid: runtime.fetch(:base_oid),
      base_branch: task.base_branch,
      origin: runtime.fetch(:origin),
      project: runtime.fetch(:project),
      repository: "acme/widgets",
      task_branch: task.slug,
      task_oid: nil,
      worktree: File.join(runtime.fetch(:worktree_root), task.slug),
      prs: [],
      push_observed: true,
      create_visible: true,
      auth_error: false,
      auth_calls: 0,
      auth_fail_after: nil
    }
  end

  def with_fake_remote(state, calls)
    owner = self
    identity = lambda do |path, cfg: nil, timeout_sec: nil, managed: false, **unexpected|
      owner.send(:assert_empty, unexpected)
      allowed_paths = managed ? [state.fetch(:worktree)] : [state.fetch(:project), state.fetch(:worktree)]
      owner.send(:assert_includes, allowed_paths, path)
      owner.send(:refute_nil, cfg) if managed || path == state.fetch(:project)
      owner.send(:assert_equal, {}, cfg) if cfg
      owner.send(:assert_nil, timeout_sec)
      {"host" => "github.com", "repository" => state.fetch(:repository)}
    end
    fetch_identity = lambda do |path, cfg|
      owner.send(:assert_equal, state.fetch(:project), path)
      owner.send(:refute_nil, cfg)
      "github.com/#{state.fetch(:repository)}"
    end
    identity_from_remote = lambda do |url|
      owner.send(:assert_equal, state.fetch(:origin), url)
      {"host" => "github.com", "repository" => state.fetch(:repository)}
    end
    auth = lambda do |cfg = nil, host: nil, timeout_sec: nil|
      owner.send(:refute_nil, cfg)
      owner.send(:assert_equal, "github.com", host)
      owner.send(:assert_nil, timeout_sec)
      calls << [:auth, host]
      state[:auth_calls] += 1
      fail_after = state[:auth_fail_after]
      if state.fetch(:auth_error) || (fail_after && state.fetch(:auth_calls) > fail_after)
        raise Hive::GhError, "auth denied"
      end
    end
    deny_capture = lambda do |*arguments, **keywords|
      raise "unexpected Hive::Gh.capture3 call: #{arguments.inspect} #{keywords.inspect}"
    end
    remote_oid = lambda do |path, branch, cfg: nil, remote: "origin", managed: false,
                           **unexpected|
      owner.send(:assert_empty, unexpected)
      owner.send(
        :assert_equal,
        owner.send(:expanded_path, state.fetch(:worktree)),
        owner.send(:expanded_path, path)
      )
      owner.send(:refute_nil, cfg)
      owner.send(:assert_equal, "origin", remote)
      owner.send(:assert_equal, true, managed)
      owner.send(
        :assert_includes, [state.fetch(:base_branch), state.fetch(:task_branch)], branch
      )
      observed = branch == state.fetch(:base_branch) ? state.fetch(:base_oid) : state[:task_oid]
      calls << [:remote_oid, branch, observed]
      observed
    end
    lookup = lambda do |path, branch, repository: nil, host: nil, cfg: nil,
                       **unexpected|
      owner.send(:assert_empty, unexpected)
      owner.send(
        :assert_equal,
        owner.send(:expanded_path, state.fetch(:worktree)),
        owner.send(:expanded_path, path)
      )
      owner.send(:assert_equal, state.fetch(:task_branch), branch)
      owner.send(:assert_equal, state.fetch(:repository), repository)
      owner.send(:assert_equal, "github.com", host)
      owner.send(:refute_nil, cfg)
      observed = state.fetch(:prs).map(&:dup)
      calls << [:lookup, branch, observed.length]
      observed
    end
    push = lambda do |path, oid, branch, cfg: nil, remote: "origin", **unexpected|
      owner.send(:assert_empty, unexpected)
      owner.send(
        :assert_equal,
        owner.send(:expanded_path, state.fetch(:worktree)),
        owner.send(:expanded_path, path)
      )
      owner.send(:assert_equal, owner.send(:git!, path, "rev-parse", "HEAD").strip, oid)
      owner.send(:assert_equal, state.fetch(:task_branch), branch)
      owner.send(:refute_nil, cfg)
      owner.send(:assert_equal, "origin", remote)
      calls << [:push, oid, branch]
      state[:task_oid] = oid if state.fetch(:push_observed)
      Hive::Gh::PushResult.new(success: true, stdout: "", stderr: "")
    end
    create = lambda do |path, repository:, host:, head:, base:, title:, body:,
                       cfg: nil, **unexpected|
      owner.send(:assert_empty, unexpected)
      owner.send(
        :assert_equal,
        owner.send(:expanded_path, state.fetch(:worktree)),
        owner.send(:expanded_path, path)
      )
      owner.send(:assert_equal, state.fetch(:repository), repository)
      owner.send(:assert_equal, "github.com", host)
      owner.send(:assert_equal, state.fetch(:task_branch), head)
      owner.send(:assert_equal, state.fetch(:base_branch), base)
      owner.send(:assert_equal, "Repair fixture answer", title)
      owner.send(:assert_equal, owner.send(:expected_pr_body), body)
      owner.send(:refute_nil, cfg)
      calls << [:create, head]
      if state.fetch(:create_visible)
        state[:prs] = [
          owner.send(
            :exact_pr_for, head, state.fetch(:task_oid), state.fetch(:base_oid)
          )
        ]
      end
      status = Hive::Gh::CommandStatus.new(
        exitstatus: state.fetch(:create_visible) ? 0 : 1
      )
      ["non-authoritative create output", "", status]
    end

    with_singleton_replacements([
      [Hive::Gh, :repository_identity, identity],
      [Hive::Gh, :repository_identity_from_remote, identity_from_remote],
      [Hive::Gh, :capture3, deny_capture],
      [Hive::Stages::AgentWorktree, :controller_fetch_repository!, fetch_identity],
      [Hive::Gh, :ensure_authenticated!, auth],
      [Hive::Gh, :remote_branch_oid, remote_oid],
      [Hive::Gh, :lookup_prs_for_branch, lookup],
      [Hive::Gh, :push_exact_oid, push],
      [Hive::Gh, :create_draft_pr, create]
    ]) { yield }
  end

  def expected_pr_body
    <<~BODY.chomp
      ## Reproduction
      The focused fixture demonstrated that the answer was 41 instead of 42.

      ## Cause
      The fixture returned the stale literal 41.

      ## Changes
      Changed lib/value.rb from 41 to 42.

      ## Tests
      ruby test/value_test.rb (pass or not applicable)

      ## Risks
      The deterministic fixture does not contact external services.
    BODY
  end

  def exact_pr(task, head_oid, base_oid)
    exact_pr_for(task.slug, head_oid, base_oid)
  end

  def exact_pr_for(branch, head_oid, base_oid)
    {
      "number" => 42,
      "url" => PR_URL,
      "state" => "OPEN",
      "isDraft" => true,
      "headRefName" => branch,
      "headRefOid" => head_oid,
      "baseRefName" => "main",
      "baseRefOid" => base_oid,
      "headRepository" => {"nameWithOwner" => "acme/widgets"}
    }
  end

  def with_singleton_replacements(replacements, index = 0, &block)
    return yield if index == replacements.length

    owner, name, replacement = replacements.fetch(index)
    original = owner.method(name)
    owner.define_singleton_method(name, replacement)
    with_singleton_replacements(replacements, index + 1, &block)
  ensure
    owner&.define_singleton_method(name, original) if original
  end

  def read_receipt(task, runtime)
    Hive::DraftPrReceipt.read(
      task.folder, worktree_root: runtime.fetch(:worktree_root)
    )
  end

  def assert_agent_prompt!(prompt)
    assert_includes prompt, "## brief.md"
    assert_includes prompt, "Repair the seeded answer defect"
    assert_includes prompt,
                    "FixtureValue.answer should return 42 without broad refactoring."
    assert_match(/Prior task artifacts.*untrusted evidence/im, prompt)
    assert_match(/<user_supplied_[0-9a-f]{16} content_type="prior_artifacts">/, prompt)
  end

  def assert_recoverable_marker(task)
    state_path = File.join(task.folder, "fix-report.md")
    marker = Hive::Markers.current(state_path)
    assert_equal :error, marker.name
    assert_equal "draft_pr_handoff_failed", marker.attrs.fetch("reason")
    assert_equal "hive run #{task.slug}", marker.attrs.fetch("retry")

    action = Hive::TaskAction.for(task, marker)
    assert_equal "recover_draft_pr", action.key
    assert_equal "hive run #{task.slug}", action.command
    observed_at = File.mtime(state_path)
    decision = Hive::Daemon::Policy.decide(
      action: action.key,
      stage: "#{task.stage_index}-#{task.stage_name}",
      workflow: task.workflow.id.to_s,
      command: action.command,
      state_file_mtime: observed_at,
      last_dispatched_state_file_mtime: nil,
      now: observed_at + 60
    )
    assert_equal :skip, decision
  end

  def controller_artifact_contents(task_folder)
    Dir.glob(File.join(task_folder, "**", "*"), File::FNM_DOTMATCH)
       .reject { |path| %w[. ..].include?(File.basename(path)) }
       .select { |path| File.file?(path) }
       .sort
       .map { |path| [path, File.binread(path)] }
  end

  def directory_fingerprint(root)
    return [] unless File.exist?(root)

    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
       .reject { |path| %w[. ..].include?(File.basename(path)) }
       .sort
       .map do |path|
      relative = path.delete_prefix("#{root}/")
      stat = File.lstat(path)
      if stat.symlink?
        [relative, "symlink", File.readlink(path)]
      elsif stat.directory?
        [relative, "directory"]
      else
        [relative, "file", stat.mode & 0o7777, Digest::SHA256.file(path).hexdigest]
      end
    end
  end

  def managed_workflow_fingerprint(project)
    directory_fingerprint(File.join(project, ".hive-state", "workflows"))
      .reject { |entry| entry.first == ".mutation.lock" }
  end

  def write_default_deny_binaries(directory)
    FileUtils.mkdir_p(directory)
    %w[gh codex claude pi grok].each do |name|
      path = File.join(directory, name)
      File.write(path, <<~SH)
        #!/bin/sh
        printf '%s\n' "unexpected external test binary: $0" >&2
        exit 97
      SH
      File.chmod(0o755, path)
    end
  end

  def checkout_fingerprint(path)
    branch, _branch_error, branch_status = Open3.capture3(
      "git", "-C", path, "symbolic-ref", "--quiet", "HEAD"
    )
    {
      "head" => git!(path, "rev-parse", "HEAD").strip,
      "branch" => branch_status.success? ? branch.strip : "DETACHED",
      "status" => git!(
        path, "status", "--porcelain=v1", "--untracked-files=all", "--ignored=matching"
      ),
      "index" => git!(path, "ls-files", "-s", "-z"),
      "index_flags" => git!(path, "ls-files", "-v", "-f", "-z")
    }
  end

  def expanded_path(path)
    File.expand_path(path)
  end

  def git!(repository, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", repository, *arguments)
    raise "git #{arguments.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end

  def with_environment(overrides)
    before = overrides.to_h do |key, _value|
      [key, ENV.key?(key) ? ENV[key] : :__missing__]
    end
    overrides.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    before&.each do |key, value|
      value == :__missing__ ? ENV.delete(key) : ENV[key] = value
    end
  end
end
