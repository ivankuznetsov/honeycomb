# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "json"
require "stringio"
require "yaml"

ROOT_CAUSE_CANDIDATE_HIVE_REVISION = "ca0c429c0f7cbf3c912f2ffdd01b04a7890374b0"
root_cause_candidate_hive_source = ENV["HONEYCOMB_HIVE_SOURCE"].to_s
ROOT_CAUSE_CANDIDATE_HIVE_ERROR = begin
  if root_cause_candidate_hive_source.empty?
    "HONEYCOMB_HIVE_SOURCE must name the pinned Hive checkout"
  elsif !File.directory?(File.join(root_cause_candidate_hive_source, "lib"))
    "HONEYCOMB_HIVE_SOURCE does not contain Hive lib/"
  else
    head, head_error, head_status = Open3.capture3(
      "git", "-C", root_cause_candidate_hive_source, "rev-parse", "HEAD"
    )
    dirty, dirty_error, dirty_status = Open3.capture3(
      "git", "-C", root_cause_candidate_hive_source,
      "status", "--porcelain=v1", "--untracked-files=all"
    )
    if !head_status.success?
      "cannot read Hive revision: #{head_error.strip}"
    elsif head.strip != ROOT_CAUSE_CANDIDATE_HIVE_REVISION
      "Hive revision #{head.strip.inspect} is not #{ROOT_CAUSE_CANDIDATE_HIVE_REVISION}"
    elsif !dirty_status.success?
      "cannot inspect Hive checkout: #{dirty_error.strip}"
    elsif !dirty.empty?
      "Hive checkout must be clean; status is #{dirty.lines.first.to_s.strip.inspect}"
    end
  end
end

$LOAD_PATH.unshift(File.join(root_cause_candidate_hive_source, "lib")) if ROOT_CAUSE_CANDIDATE_HIVE_ERROR.nil?
ROOT_CAUSE_CANDIDATE_HIVE_LOAD_ERROR = begin
  if ROOT_CAUSE_CANDIDATE_HIVE_ERROR.nil?
    require "hive"
    require "hive/commands/new"
    require "hive/commands/workflow/install"
    require "hive/markers"
    require "hive/stages/agent"
    require "hive/task"
    require "hive/workflow_package/registry_client"
  end
  nil
rescue LoadError => e
  e
end

class RootCauseRepairCandidateHiveExecutionTest < Minitest::Test
  PACKAGE_NAME = "root-cause-repair"
  TEST_VERSION = "0.0.0"
  CANDIDATE_ROOT = File.join(ROOT, "candidates", PACKAGE_NAME)
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
    assert_nil ROOT_CAUSE_CANDIDATE_HIVE_ERROR, ROOT_CAUSE_CANDIDATE_HIVE_ERROR
    assert_nil ROOT_CAUSE_CANDIDATE_HIVE_LOAD_ERROR,
               "pinned Hive could not be loaded: #{ROOT_CAUSE_CANDIDATE_HIVE_LOAD_ERROR&.message}"
  end

  def test_real_linked_hive_state_and_concurrent_branch_reach_diagnosis
    with_sandbox do |registry, project, state_root|
      install(registry, project)
      path = create_task(project, "linked-ref-regression")
      reproduce_path = move_task(project, path, "reproduce")

      with_deterministic_agent(:reproduce) do
        result = Hive::Stages::Agent.run!(Hive::Task.new(reproduce_path), {})
        assert_equal :complete, result.fetch(:status)
      end
      reproduce = File.read(File.join(reproduce_path, "reproduce.md"))
      digest = reproduce[/Checkpoint-Digest: (sha256:[0-9a-f]{64})/, 1]
      refute_nil digest

      diagnose_path = move_task(project, reproduce_path, "diagnose")
      git!(state_root, "add", "-A")
      git!(state_root, "commit", "-qm", "advance reproduce to diagnose")
      git!(project, "branch", "another-task")

      with_deterministic_agent(:diagnose) do
        result = Hive::Stages::Agent.run!(Hive::Task.new(diagnose_path), {})
        assert_equal :complete, result.fetch(:status)
      end
      diagnose = File.read(File.join(diagnose_path, "diagnose.md"))
      assert_match(/\AWorkflow-Status: continue\n/, diagnose)
      comparison = JSON.parse(diagnose[/Repository-Authority: (\{.*\})$/, 1])
      assert_equal "continue", comparison.fetch("verdict")
      assert_equal "unrelated_refs", comparison.fetch("reason")
      assert_equal ["refs/heads/another-task", "refs/heads/hive/state"],
                   comparison.dig("changes", "unrelated", "records").map { |entry| entry.fetch("name") }
      assert_equal "refs/heads/main", comparison.dig("snapshot", "head", "symbolic")
    end
  end

  def test_target_branch_movement_still_blocks_before_diagnosis
    with_sandbox do |registry, project, state_root|
      install(registry, project)
      path = move_task(project, create_task(project, "target-drift"), "reproduce")
      with_deterministic_agent(:reproduce) do
        Hive::Stages::Agent.run!(Hive::Task.new(path), {})
      end
      diagnose_path = move_task(project, path, "diagnose")
      git!(state_root, "add", "-A")
      git!(state_root, "commit", "-qm", "advance reproduce to diagnose")
      original = git!(project, "rev-parse", "HEAD").strip
      advanced = git!(project, "commit-tree", "HEAD^{tree}", "-p", original, "-m", "owner advanced target").strip
      git!(project, "update-ref", "refs/heads/main", advanced, original)

      with_deterministic_agent(:diagnose) do
        Hive::Stages::Agent.run!(Hive::Task.new(diagnose_path), {})
      end
      diagnose = File.read(File.join(diagnose_path, "diagnose.md"))
      assert_match(/\AWorkflow-Status: blocked\n/, diagnose)
      comparison = JSON.parse(diagnose[/Repository-Authority: (\{.*\})$/, 1])
      assert_equal "blocked", comparison.fetch("verdict")
      assert_equal "target_changed", comparison.fetch("reason")
    end
  end

  private

  def with_sandbox
    Dir.mktmpdir("honeycomb-root-cause-candidate-hive") do |sandbox|
      registry = build_registry(File.join(sandbox, "registry"))
      home = File.join(sandbox, "hive-home")
      FileUtils.mkdir_p(home)
      File.write(File.join(home, "config.yml"), {"registered_projects" => []}.to_yaml)
      with_environment("HIVE_HOME" => home) do
        project, state_root = build_project(File.join(sandbox, "target"))
        yield registry, project, state_root
      end
    ensure
      FileUtils.chmod_R(0o700, sandbox) if sandbox && File.exist?(sandbox)
      Hive::Workflows::Project.reset! if defined?(Hive::Workflows::Project)
    end
  end

  def build_project(path)
    FileUtils.mkdir_p(path)
    git!(path, "init", "-q", "-b", "main")
    git!(path, "config", "user.name", "Root Cause Candidate")
    git!(path, "config", "user.email", "candidate@example.test")
    File.write(File.join(path, ".gitignore"), ".hive-state/\n")
    File.write(File.join(path, "tracked.txt"), "target\n")
    git!(path, "add", ".")
    git!(path, "commit", "-qm", "seed target")

    state_root = File.join(path, ".hive-state")
    git!(path, "worktree", "add", "-q", "--detach", state_root, "HEAD")
    git!(state_root, "switch", "-q", "--orphan", "hive/state")
    Dir.each_child(state_root) do |entry|
      FileUtils.rm_rf(File.join(state_root, entry)) unless entry == ".git"
    end
    FileUtils.mkdir_p(File.join(state_root, "stages"))
    FileUtils.mkdir_p(File.join(state_root, "logs"))
    File.write(
      File.join(state_root, "config.yml"),
      Hive::Config::DEFAULTS.merge("hive_state_path" => ".hive-state").to_yaml
    )
    File.write(File.join(state_root, "stages", ".gitkeep"), "")
    File.write(File.join(state_root, "logs", ".gitkeep"), "")
    git!(state_root, "add", ".")
    git!(state_root, "commit", "-qm", "bootstrap linked Hive state")
    Hive::Config.register_project(
      name: File.basename(path), path: path, repository_identity: nil
    )
    [path, state_root]
  end

  def install(registry, project)
    client = Hive::WorkflowPackage::RegistryClient.new(repository: registry)
    overrides = MAPPING_SLOTS.map { |slot| "#{slot}=codex" }
    Hive::Commands::Workflow::Install.new(
      "honeycomb/#{PACKAGE_NAME}@#{TEST_VERSION}",
      project_root: project, json: true, yes: true, allow_escalation: true,
      mapping_overrides: overrides, input_bindings: [], stdout: StringIO.new,
      registry_client: client, committer: ->(*) { }
    ).call!
  end

  def create_task(project, slug)
    capture_io do
      Hive::Commands::New.new(
        File.basename(project), "Repair the seeded defect", slug_override: slug,
        body_override: "Prove repository authority before diagnosis.",
        workflow: PACKAGE_NAME
      ).call!
    end
    File.join(project, ".hive-state", "stages", "1-inbox", slug)
  end

  def move_task(project, current_path, stage_name)
    stage = Hive::Task.new(current_path).workflow.stage_named(stage_name)
    parent = File.join(project, ".hive-state", "stages", stage.dir)
    FileUtils.mkdir_p(parent)
    destination = File.join(parent, File.basename(current_path))
    FileUtils.mv(current_path, destination)
    destination
  end

  def with_deterministic_agent(stage)
    original = Hive::Stages::Base.method(:spawn_agent)
    owner = self
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |task, **kwargs|
      owner.send(:run_deterministic_agent, stage, task, **kwargs)
    end
    yield
  ensure
    Hive::Stages::Base.define_singleton_method(:spawn_agent, original) if original
  end

  def run_deterministic_agent(stage, task, cwd:, log_label:, **_kwargs)
    raise "unexpected stage #{log_label}" unless log_label == stage.to_s

    context = task.managed_runtime_context("stages.#{stage}")
    tool = context.fetch(:tools).find do |path|
      File.basename(path) == "repository-state.rb"
    end
    instruction = File.read(File.join(context.fetch(:package_root), "instructions", "#{stage}.md"))
    output = if stage == :reproduce
               assert_match(/repository-state\.rb`?\s+`?create/i, instruction)
               created = run_tool!(tool, task.folder, "create")
               digest = created.dig("checkpoint", "digest")
               inventoried = run_tool!(tool, task.folder, "inventory", "--expect", digest)
               run_tool!(
                 tool, task.folder, "advance", "--allow-worktree",
                 inventoried.dig("worktree_changes", "digest"), "--expect", digest
               )
             else
               assert_match(/repository-state\.rb`?\s+`?compare\s+--expect/i, instruction)
               digest = File.read(File.join(task.folder, "reproduce.md"))[/Checkpoint-Digest: (sha256:[0-9a-f]{64})/, 1]
               run_tool!(tool, task.folder, "compare", "--expect", digest)
             end
    assert_match(/repository-state\.rb`?\s+`?inventory\s+--expect/i, instruction)
    assert_match(/repository-state\.rb`?\s+`?advance\s+--allow-worktree/i, instruction)
    status = output.fetch("verdict") == "continue" ? "continue" : "blocked"
    body = <<~MD
      Workflow-Status: #{status}
      Checkpoint-Digest: #{output.dig("checkpoint", "digest")}
      Repository-Authority: #{JSON.generate(output)}

      <!-- COMPLETE -->
    MD
    File.write(File.join(cwd, task.workflow.stage_named(log_label).state_file), body)
    {status: :ok}
  end

  def run_tool!(tool, folder, *arguments)
    stdout, stderr, status = Open3.capture3(tool, *arguments, chdir: folder)
    raise "repository-state failed: #{stderr} #{stdout}" unless status.success?

    JSON.parse(stdout)
  end

  def build_registry(path)
    FileUtils.mkdir_p(path)
    git!(path, "init", "-q", "-b", "main")
    git!(path, "config", "user.email", "candidate@example.test")
    git!(path, "config", "user.name", "Candidate registry")
    destination = File.join(path, "packages", PACKAGE_NAME, TEST_VERSION)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp_r(CANDIDATE_ROOT, destination)
    git!(path, "add", "packages")
    git!(path, "commit", "-qm", "ephemeral candidate behavior source")
    source_revision = git!(path, "rev-parse", "HEAD").strip

    package = HoneycombRegistry::Package.new(destination, root: path)
    File.write(package.manifest_path, YAML.dump(manifest_metadata(source_revision)))
    generated = HoneycombRegistry::Manifest.generate(package)
    raise generated.findings.to_h.inspect if generated.findings.errors?
    git!(path, "add", "packages")
    git!(path, "commit", "-qm", "ephemeral candidate manifest")
    review_head = git!(path, "rev-parse", "HEAD").strip

    catalog = {
      "schema" => "honeycomb-catalog/v2",
      "entries" => [catalog_entry(generated.document, source_revision, review_head)]
    }
    File.binwrite(
      File.join(path, "catalog.json"), HoneycombRegistry::CanonicalJSON.dump(catalog)
    )
    git!(path, "add", "catalog.json")
    git!(path, "commit", "-qm", "ephemeral candidate catalog")
    path
  end

  def manifest_metadata(source_revision)
    {
      "schema" => "honeycomb-manifest/v1",
      "name" => PACKAGE_NAME,
      "version" => TEST_VERSION,
      "description" => "Root Cause Repair candidate execution fixture",
      "author" => {"name" => "Honeycomb maintainers", "url" => "https://example.test"},
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

  def catalog_entry(manifest, source_revision, review_head)
    permissions = manifest.fetch("permissions")
    {
      "name" => PACKAGE_NAME,
      "version" => TEST_VERSION,
      "latest_version" => TEST_VERSION,
      "description" => manifest.fetch("description"),
      "release_tier" => "community",
      "current_tier" => "community",
      "permission_risk" => permissions.fetch("risk"),
      "state" => "listed",
      "discoverable" => true,
      "exact_resolution" => "allowed",
      "verification" => nil,
      "history" => [],
      "advisories" => [],
      "author" => manifest.fetch("author"),
      "license" => manifest.fetch("license"),
      "hive_min_version" => manifest.fetch("hive_min_version"),
      "permissions" => permissions,
      "install_command" => "hive workflow install honeycomb/#{PACKAGE_NAME}",
      "package_url" => "https://example.test/packages/#{PACKAGE_NAME}/#{TEST_VERSION}",
      "reviews_url" => "https://example.test/reviews/#{PACKAGE_NAME}/#{TEST_VERSION}",
      "community_reviews_url" => nil,
      "source_sha" => source_revision,
      "listing_approval" => {
        "release_sha256" => manifest.fetch("release_sha256"),
        "head_sha" => review_head,
        "lint_checked_at" => "2026-08-02T00:00:00Z",
        "approved_by" => ["fixture-owner"],
        "approved_at" => "2026-08-02T00:00:01Z",
        "reviews" => [{
          "reviewer" => "fixture-owner",
          "reviewed_at" => "2026-08-02T00:00:01Z",
          "review_url" => "https://example.test/reviews/root-cause/fixture-owner",
          "evidence_digest" => Digest::SHA256.hexdigest("root-cause-candidate")
        }]
      }
    }
  end

  def git!(repository, *arguments)
    stdout, stderr, status = Open3.capture3(
      "git", "-c", "commit.gpgsign=false", "-C", repository, *arguments
    )
    raise "git #{arguments.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end

  def with_environment(overrides)
    before = overrides.to_h do |key, _value|
      [key, ENV.key?(key) ? ENV[key] : :__missing__]
    end
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    before&.each do |key, value|
      value == :__missing__ ? ENV.delete(key) : ENV[key] = value
    end
  end
end
