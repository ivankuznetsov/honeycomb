# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "json"
require "yaml"

hive_source = ENV["HONEYCOMB_HIVE_SOURCE"]
$LOAD_PATH.unshift(File.join(hive_source, "lib")) if hive_source && File.directory?(File.join(hive_source, "lib"))

begin
  require "hive"
  require "hive/commands/new"
  require "hive/commands/workflow/install"
  require "hive/task"
  require "hive/stages/agent"
  require "hive/stages/council"
  require "hive/workflow_package/managed_store"
  require "hive/workflow_package/registry_client"
rescue LoadError => e
  FLAGSHIP_HIVE_LOAD_ERROR = e
end

class FlagshipHiveExecutionTest < Minitest::Test
  FLAGSHIPS = %w[architecture writing seo-content].freeze
  OPTIONAL_SEO_INPUTS = %w[
    AHREFS_API_KEY
    DATAFORSEO_LOGIN
    DATAFORSEO_PASSWORD
    GA4_ACCESS_TOKEN
    GA4_PROPERTY_ID
    GSC_ACCESS_TOKEN
  ].freeze

  def test_real_hive_install_create_and_runtime_context_for_all_flagships
    require_flagship_hive!

    with_flagship_sandbox do |sandbox|
      registry = build_test_registry(File.join(sandbox, "registry"))
      with_hive_home(File.join(sandbox, "hive-home")) do
        project = build_project(File.join(sandbox, "project"))
        client = Hive::WorkflowPackage::RegistryClient.new(repository: registry)
        installed = {}
        tasks = {}

        FLAGSHIPS.each do |name|
          mapping_overrides = if name == "architecture"
                                [ "stages.review.reviewers.operations=claude,model=fixture-reviewer" ]
                              else
                                []
                              end
          input_bindings = if name == "seo-content"
                             [
                               "GA4_PROPERTY_ID=FLAGSHIP_GA4_PROPERTY",
                               "GSC_ACCESS_TOKEN=FLAGSHIP_GSC_TOKEN"
                             ]
                           else
                             []
                           end
          installed[name] = Hive::Commands::Workflow::Install.new(
            "honeycomb/#{name}@1.0.0", project_root: project, json: true, yes: true,
            allow_escalation: true, mapping_overrides: mapping_overrides,
            input_bindings: input_bindings, stdout: StringIO.new,
            registry_client: client, committer: ->(*) { }
          ).call!
          tasks[name] = create_managed_task(project, name)
        end

        installed.each do |name, payload|
          assert_equal "installed", payload.fetch("status"), name
          assert_match(/\A[0-9a-f]{40}\z/, payload.fetch("catalog_commit"), name)
          assert_match(/\A[0-9a-f]{64}\z/, payload.fetch("manifest_digest"), name)
          assert_match(/\A[0-9a-f]{64}\z/, payload.fetch("configuration_digest"), name)
          refute_empty payload.fetch("mappings"), name

          task = Hive::Task.new(tasks.fetch(name))
          assert_equal payload.fetch("catalog_commit"), task.workflow_commit, name
          assert_equal payload.fetch("manifest_digest"), task.workflow_manifest_digest, name
          assert_equal payload.fetch("configuration_digest"), task.workflow_configuration_digest, name
          assert_equal name.to_sym, task.workflow.id, name
        end

        customized = installed.fetch("architecture").fetch("mappings").find do |mapping|
          mapping.fetch("slot") == "stages.review.reviewers.operations"
        end
        assert_equal "claude", customized.fetch("agent")
        assert_equal "fixture-reviewer", customized.fetch("model")
        assert_equal "reviewer", customized.fetch("mapping_role")

        seo_task = Hive::Task.new(tasks.fetch("seo-content"))
        absent = seo_task.managed_runtime_context("stages.provider-data")
        assert_empty absent.fetch(:environment)
        assert absent.fetch(:input_statuses).all? { |input| input.fetch("available") == false }

        with_environment("FLAGSHIP_GA4_PROPERTY" => "fixture-property") do
          partial = seo_task.managed_runtime_context("stages.provider-data")
          assert_equal({ "GA4_PROPERTY_ID" => "fixture-property" }, partial.fetch(:environment))
          assert partial.fetch(:input_statuses).any? { |input| input.fetch("available") }
          assert partial.fetch(:input_statuses).any? { |input| !input.fetch("available") }
          refute_includes File.binread(configuration_path(project, installed.fetch("seo-content"))),
                          "fixture-property"
        end

        optimize = seo_task.managed_runtime_context("stages.optimize")
        assert_empty optimize.fetch(:environment), "SEO inputs must not cross the research-slot boundary"
        tool = optimize.fetch(:tools).find { |path| File.basename(path) == "seo-analyze.rb" }
        assert File.executable?(tool), "materialized package tool must retain mode 100755"
        analyzer = run_analyzer(tool, File.join(tasks.fetch("seo-content"), "fixture-article.md"))
        assert_equal "seo-analyzer/v1", analyzer.fetch("schema")
        assert_operator analyzer.fetch("word_count"), :>, 0
      end
    end
  end

  # This is intentionally a deterministic package-content check, not a claim
  # that provider-backed agents or the council scheduler ran in this process.
  # The lifecycle test above owns Hive materialization, mapping, pinning, and
  # package context; these fixtures own each package's publishability rubric.
  def test_deterministic_terminal_artifacts_satisfy_package_quality_rubrics
    architecture = flagship_fixture("architecture", "architecture.md")
    assert_match(/`[^`]+:\d+`/, architecture)
    %w[constraints tradeoffs components data\ flow reviewer\ resolution].each do |term|
      assert_match(/#{term}/i, architecture)
    end

    writing_verifications = %w[ready ungrounded five-round-cap].map do |outcome|
      flagship_fixture("writing", "verification-#{outcome}.md")
    end
    terminal_reasons = writing_verifications.map { |report| report[/terminal reason: ([a-z-]+)/i, 1] }
    assert_equal %w[ready ungrounded five-round-cap], terminal_reasons
    assert_match(/claim: .+ -> source:/i, writing_verifications.first)
    assert_match(/revision delta:/i, writing_verifications.first)

    seo = %w[intent outline article verification humanization optimization].to_h do |artifact|
      [ artifact, flagship_fixture("seo-content", "#{artifact}.md") ]
    end
    assert_includes seo.fetch("article"), "provenance, mappings, and quality gates"
    assert_match(/claim-level status: (verified|qualified)/i, seo.fetch("verification"))
    assert_match(/finding:.+addressed:/im, seo.fetch("humanization"))
    assert_match(/measured .+target .+priority:/im, seo.fetch("optimization"))
  end

  def test_real_hive_stage_and_council_engines_reach_flagship_outcomes
    require_flagship_hive!

    with_flagship_sandbox do |sandbox|
      registry = build_test_registry(File.join(sandbox, "registry"))
      with_hive_home(File.join(sandbox, "hive-home")) do
        project = build_project(File.join(sandbox, "project"))
        client = Hive::WorkflowPackage::RegistryClient.new(repository: registry)
        task_paths = {}
        FLAGSHIPS.each do |name|
          Hive::Commands::Workflow::Install.new(
            "honeycomb/#{name}@1.0.0", project_root: project, json: true, yes: true,
            allow_escalation: true, mapping_overrides: [], input_bindings: [],
            stdout: StringIO.new, registry_client: client, committer: ->(*) { }
          ).call!
          task_paths[name] = create_managed_task(project, name)
        end

        with_deterministic_agents(:ready) do
          architecture = run_workflow_engines(project, task_paths.fetch("architecture"))
          assert_equal :complete, Hive::Markers.current(File.join(architecture, "architecture.md")).name
          assert_includes File.read(File.join(architecture, "architecture.md")), "architecture engine proof"
        end

        with_deterministic_agents(:five_round_cap) do
          writing = run_workflow_engines(project, task_paths.fetch("writing"))
          verification = File.read(File.join(writing, "verification.md"))
          assert_includes verification, "terminal_reason: five-round-cap"
          assert_includes File.read(File.join(writing, "article.md")), "NOT PUBLISHABLE"
        end

        with_deterministic_agents(:prompt_only) do
          seo = run_workflow_engines(project, task_paths.fetch("seo-content"))
          assert_includes File.read(File.join(seo, "provider-data.md")), '"mode":"prompt-only"'
          assert_includes File.read(File.join(seo, "analysis.md")), '"schema": "seo-analyzer/v1"'
          assert_equal :complete, Hive::Markers.current(File.join(seo, "article.md")).name
        end
      end
    end
  end

  private

  def run_workflow_engines(project, initial_path)
    path = initial_path
    workflow = Hive::Task.new(path).workflow
    workflow.stages.drop(1).each do |stage|
      path = move_task_to_stage(project, path, stage)
      task = Hive::Task.new(path)
      result = if stage.kind == :council
                 Hive::Stages::Council.run!(task, {})
               else
                 Hive::Stages::Agent.run!(task, {})
               end
      assert_equal :complete, result.fetch(:status), "#{workflow.id}:#{stage.name}"
    end
    path
  end

  def move_task_to_stage(project, current_path, stage)
    parent = File.join(project, ".hive-state", "stages", stage.dir)
    FileUtils.mkdir_p(parent)
    destination = File.join(parent, File.basename(current_path))
    FileUtils.mv(current_path, destination)
    destination
  end

  def with_deterministic_agents(scenario)
    original = Hive::Stages::Base.method(:spawn_agent)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |task, prompt:, cwd:, log_label:, expected_output: nil, **_kwargs|
      if expected_output
        if log_label.end_with?("-revise")
          File.write(expected_output, "# Revised draft\n\nDeterministic revision.\n\n<!-- COMPLETE -->\n")
        else
          verdict = scenario == :five_round_cap ? "changes_requested" : "ready"
          FileUtils.mkdir_p(File.dirname(expected_output))
          File.write(expected_output, "Verdict: #{verdict}\n\n# Findings\n\nDeterministic.\n\n# Required edits\n\nNone.\n")
        end
      else
        state_file = prompt[/^State file: (.+)$/, 1]
        raise "deterministic agent could not resolve state file" unless state_file

        output_path = File.join(cwd, state_file)
        body = "# #{log_label}\n\nDeterministic engine proof.\n"
        case log_label
        when "architecture"
          body << "\narchitecture engine proof with constraints, tradeoffs, components, and data flow.\n"
        when "provider-data"
          tool = task.managed_runtime_context("stages.provider-data").fetch(:tools)
                     .find { |path| File.basename(path) == "provider-metrics.rb" }
          stdout, stderr, status = Open3.capture3(
            tool, stdin_data: JSON.generate("keywords" => ["hive workflows"], "site_url" => "https://example.test")
          )
          raise stderr unless status.success?
          body << "\n#{stdout}"
        when "analyze"
          tool = task.managed_runtime_context("stages.analyze").fetch(:tools)
                     .find { |path| File.basename(path) == "seo-analyze.rb" }
          stdout, stderr, status = Open3.capture3(tool, File.join(cwd, "draft.md"))
          raise stderr unless status.success?
          body << "\n```json\n#{stdout}```\n"
        when "deliver"
          File.write(
            File.join(cwd, "verification.md"),
            "grounding: grounded\nterminal_reason: five-round-cap\nrounds: 5\n\n<!-- COMPLETE -->\n"
          )
          body << "\nNOT PUBLISHABLE: editorial cap reached.\n" if scenario == :five_round_cap
        end
        File.write(output_path, "#{body}\n<!-- COMPLETE -->\n")
      end
      {status: :ok}
    end
    yield
  ensure
    Hive::Stages::Base.define_singleton_method(:spawn_agent, original)
  end

  def flagship_fixture(package, filename)
    File.read(fixture_path("flagships", package, filename))
  end

  def with_flagship_sandbox
    sandbox = Dir.mktmpdir("honeycomb-flagship-hive-test")
    yield sandbox
  ensure
    # Hive deliberately makes installed generation directories read-only. Make
    # this one known test sandbox owner-writable again before removing it.
    FileUtils.chmod_R(0o700, sandbox) if sandbox && File.exist?(sandbox)
    FileUtils.rm_rf(sandbox) if sandbox
  end

  def require_flagship_hive!
    if defined?(FLAGSHIP_HIVE_LOAD_ERROR)
      skip "compatible Hive source is unavailable: #{FLAGSHIP_HIVE_LOAD_ERROR.message}"
    end
    return if defined?(Hive::WorkflowPackage::Configuration) &&
              Hive::Commands::Workflow::Install.instance_method(:initialize).parameters.flatten.include?(:mapping_overrides)

    skip "compatible flagship Hive runtime is unavailable; set HONEYCOMB_HIVE_SOURCE"
  end

  def build_test_registry(path)
    FileUtils.mkdir_p(path)
    git!(path, "init", "-b", "main")
    git!(path, "config", "user.email", "flagship@example.test")
    git!(path, "config", "user.name", "Flagship fixture")
    FLAGSHIPS.each do |name|
      destination = File.join(path, "packages", name, "1.0.0")
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp_r(File.join(ROOT, "packages", name, "1.0.0"), destination)
    end
    git!(path, "add", "packages")
    git!(path, "commit", "-m", "fixture behavior source")
    source_revision = git!(path, "rev-parse", "HEAD").strip

    manifests = FLAGSHIPS.to_h do |name|
      package_path = File.join(path, "packages", name, "1.0.0")
      File.write(File.join(package_path, "manifest.yml"), YAML.dump(
        manifest_metadata(name, source_revision)
      ))
      package = HoneycombRegistry::Package.new(package_path, root: path)
      result = HoneycombRegistry::Manifest.generate(package)
      if result.findings.errors?
        raise "fixture manifest failed for #{name}: #{result.findings.to_h.inspect}"
      end
      [ name, result.document ]
    end
    git!(path, "add", "packages")
    git!(path, "commit", "-m", "fixture generated manifests")
    release_head = git!(path, "rev-parse", "HEAD").strip

    entries = manifests.map do |name, manifest|
      catalog_entry(name, manifest, source_revision: source_revision, review_head: release_head)
    end
    File.binwrite(File.join(path, "catalog.json"), HoneycombRegistry::CanonicalJSON.dump(
      "schema" => "honeycomb-catalog/v2", "entries" => entries
    ))
    git!(path, "add", "catalog.json")
    git!(path, "commit", "-m", "fixture catalog")
    path
  end

  def manifest_metadata(name, source_revision)
    metadata = {
      "schema" => "honeycomb-manifest/v1",
      "name" => name,
      "version" => "1.0.0",
      "description" => "Deterministic #{name} flagship fixture",
      "author" => { "name" => "Honeycomb maintainers", "url" => "https://example.test/honeycomb" },
      "license" => "MIT",
      "hive_min_version" => "0.6.0",
      "source" => {
        "url" => "https://example.test/honeycomb/commit/#{source_revision}",
        "revision" => source_revision
      },
      "x-hive" => { "tools" => [], "prompt_assets" => [], "optional_inputs" => [] }
    }
    if name == "seo-content"
      metadata["x-hive"] = {
        "tools" => [ { "path" => "tools/provider-metrics.rb" }, { "path" => "tools/seo-analyze.rb" } ],
        "prompt_assets" => [ { "path" => "assets/quality-rubric.md" } ],
        "optional_inputs" => OPTIONAL_SEO_INPUTS.map do |input|
          { "name" => input, "authorized_slots" => [ "stages.provider-data" ] }
        end
      }
    end
    metadata
  end

  def catalog_entry(name, manifest, source_revision:, review_head:)
    permissions = manifest.fetch("permissions")
    {
      "name" => name,
      "version" => "1.0.0",
      "latest_version" => "1.0.0",
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
      "install_command" => "hive workflow install honeycomb/#{name}",
      "package_url" => "https://example.test/packages/#{name}/1.0.0",
      "reviews_url" => "https://example.test/reviews/#{name}/1.0.0",
      "community_reviews_url" => nil,
      "source_sha" => source_revision,
      "listing_approval" => {
        "release_sha256" => manifest.fetch("release_sha256"),
        "head_sha" => review_head,
        "lint_checked_at" => "2026-07-18T20:00:00Z",
        "approved_by" => %w[fixture-a fixture-b],
        "approved_at" => "2026-07-18T20:01:00Z",
        "reviews" => %w[fixture-a fixture-b].map do |reviewer|
          {
            "reviewer" => reviewer,
            "reviewed_at" => "2026-07-18T20:01:00Z",
            "review_url" => "https://example.test/reviews/#{name}/#{reviewer}",
            "evidence_digest" => Digest::SHA256.hexdigest("#{name}:#{reviewer}")
          }
        end
      }
    }
  end

  def build_project(path)
    state = File.join(path, ".hive-state")
    FileUtils.mkdir_p(File.join(state, "stages"))
    FileUtils.mkdir_p(File.join(state, "logs"))
    File.write(File.join(state, "config.yml"), Hive::Config::DEFAULTS.merge(
      "hive_state_path" => ".hive-state"
    ).to_yaml)
    git!(state, "init", "-b", "hive-state")
    git!(state, "config", "user.email", "flagship@example.test")
    git!(state, "config", "user.name", "Flagship fixture")
    git!(state, "add", ".")
    git!(state, "commit", "-m", "bootstrap fixture state")
    Hive::Config.register_project(name: File.basename(path), path: path, repository_identity: nil)
    path
  end

  def create_managed_task(project, workflow)
    slug = "flagship-#{workflow}-260718-aa"
    capture_io do
      Hive::Commands::New.new(
        File.basename(project), "Run the #{workflow} flagship fixture",
        slug_override: slug, body_override: "Deterministic flagship acceptance brief.", workflow: workflow
      ).call!
    end
    File.join(project, ".hive-state", "stages", "1-inbox", slug)
  end

  def configuration_path(project, payload)
    File.join(
      project, ".hive-state", "workflows", payload.fetch("name"), "configurations",
      "#{payload.fetch('configuration_digest')}.json"
    )
  end

  def run_analyzer(tool, article)
    File.write(article, "# Flagship proof\n\nConcrete package execution evidence.\n\n## Result\n\nVerified.\n")
    stdout, stderr, status = Open3.capture3(tool, article)
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def git!(repository, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", repository, *arguments)
    raise "git #{arguments.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end

  def with_hive_home(path)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "config.yml"), { "registered_projects" => [] }.to_yaml)
    with_environment("HIVE_HOME" => path) { yield }
  end

  def with_environment(overrides)
    before = overrides.to_h { |key, _| [ key, ENV.key?(key) ? ENV[key] : :__missing__ ] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    before&.each do |key, value|
      value == :__missing__ ? ENV.delete(key) : ENV[key] = value
    end
  end
end
