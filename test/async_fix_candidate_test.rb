# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/async_fix_registry"

class AsyncFixCandidateTest < Minitest::Test
  include AsyncFixRegistrySupport

  CANDIDATE_ROOT = File.join(ROOT, "candidates", "async-fix")
  IDENTITY_KEYS = %w[agent model effort].freeze
  EXPECTED_FILES = %w[
    README.md
    assets/fix-report-contract.md
    instructions/fix.md
    workflow.yml
  ].freeze

  def test_workflow_has_exactly_one_terminal_repair_agent
    workflow = load_workflow

    assert_equal "async-fix", workflow.fetch("id")
    assert_equal %w[inbox fix], workflow.fetch("stages").map { |stage| stage.fetch("name") }
    assert_equal(
      {"name" => "inbox", "kind" => "terminal", "state_file" => "brief.md"},
      stage(workflow, "inbox")
    )

    fix = stage(workflow, "fix")
    assert_equal(
      %w[
        deliverable handoff instruction kind mapping_contract mapping_role name
        permissions state_file workspace
      ],
      fix.keys.sort
    )
    assert_equal "agent", fix.fetch("kind")
    assert_equal "fix-report.md", fix.fetch("state_file")
    assert_equal "fix-report.md", fix.fetch("deliverable")
    assert_equal "instructions/fix.md", fix.fetch("instruction")
    assert_equal "development", fix.fetch("mapping_role")
    assert_equal "async-fix-fix-v1", fix.fetch("mapping_contract")
    assert_equal "yolo", fix.fetch("permissions")
    assert_equal "worktree", fix.fetch("workspace")
    assert_equal "draft_pr", fix.fetch("handoff")
    assert_empty recursive_keys(workflow) & IDENTITY_KEYS
    refute fix.key?("skill")
  end

  def test_instruction_is_self_contained_and_preserves_the_authority_boundary
    instruction = File.read(File.join(CANDIDATE_ROOT, "instructions", "fix.md"))
    report_contract = File.read(
      File.join(CANDIDATE_ROOT, "assets", "fix-report-contract.md")
    )
    corpus = "#{instruction}\n#{report_contract}"

    [
      /smallest cause-supported/i,
      /compact plan/i,
      /debug(?:ging)? loop/i,
      /focused regression/i,
      /hooks? and signing|signing and hooks?/i,
      /Decision: ready\|no-fix\|blocked/,
      /Suggested PR title/,
      /repository.*untrusted|untrusted.*repository/i,
      /do not run `?gh`?/i,
      /never.*force-push/i,
      /never.*merge/i,
      /never.*release/i,
      /never.*deploy/i
    ].each { |pattern| assert_match pattern, corpus }

    assert_match(/one mapped agent/i, instruction)
    assert_match(/no brainstorming|do not brainstorm/i, instruction)
    assert_match(/Hive.*push.*draft pull request|controller.*push.*draft pull request/im, corpus)
    refute_match(%r{(?:^|\s)/(?:ce-)?(?:debug|plan|brainstorm)\b}i, corpus)
    refute_match(/package tool|tools\//i, corpus)
  end

  def test_candidate_is_manifest_free_and_invisible_to_package_commands
    relative_files = Dir.glob(File.join(CANDIDATE_ROOT, "**", "*"), File::FNM_DOTMATCH)
                        .select { |path| File.file?(path) }
                        .map { |path| path.delete_prefix("#{CANDIDATE_ROOT}/") }
                        .sort
    assert_equal EXPECTED_FILES, relative_files
    refute File.exist?(File.join(CANDIDATE_ROOT, "manifest.yml"))
    assert_empty Dir.glob(File.join(CANDIDATE_ROOT, "*", "manifest.yml"))
    refute File.exist?(File.join(ROOT, "packages", "async-fix"))
    refute JSON.parse(File.read(File.join(ROOT, "catalog.json"))).fetch("entries")
               .any? { |entry| entry.fetch("name") == "async-fix" }

    discovery = HoneycombRegistry::Package.discover(ROOT)
    refute discovery.findings.errors?, discovery.findings.to_h.inspect
    refute discovery.packages.any? { |package| package.path.start_with?(CANDIDATE_ROOT) }

    in_tmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "packages"))
      FileUtils.mkdir_p(File.join(root, "candidates"))
      FileUtils.cp_r(CANDIDATE_ROOT, File.join(root, "candidates", "async-fix"))

      temporary_discovery = HoneycombRegistry::Package.discover(root)
      refute temporary_discovery.findings.errors?, temporary_discovery.findings.to_h.inspect
      assert_empty temporary_discovery.packages,
                   "package discovery must ignore copied unversioned candidates"

      stdout, stderr, status = capture_command(
        File.join(ROOT, "script", "honeycomb-manifest"), "--root", root, "--check", "--all"
      )
      assert status.success?, [stdout, stderr].join("\n")

      catalog = File.join(root, "catalog.json")
      stdout, stderr, status = capture_command(
        File.join(ROOT, "script", "honeycomb-catalog"),
        "--root", root,
        "--output", catalog,
        "--evidence", fixture_path("listing-evidence", "empty.json")
      )
      assert status.success?, [stdout, stderr].join("\n")
      assert_empty JSON.parse(File.read(catalog)).fetch("entries")
    end
  end

  def test_temporary_registry_derives_high_risk_medium_recommended_package
    with_async_fix_registry do |registry|
      manifest = registry.manifest

      assert_equal "0.0.0", manifest.fetch("version")
      assert_equal registry.source_revision, manifest.dig("source", "revision")
      assert_equal "high", manifest.dig("permissions", "risk")
      %w[network_hosts filesystem_read filesystem_write secrets].each do |field|
        assert_equal ["*"], manifest.dig("permissions", field), field
      end
      assert_equal [], manifest.dig("x-hive", "tools")
      assert_equal [], manifest.dig("x-hive", "optional_inputs")
      assert_equal(
        [{"path" => "assets/fix-report-contract.md"}],
        manifest.dig("x-hive", "prompt_assets")
      )
      assert_equal(
        [{"slot" => "stages.fix", "effort" => "medium"}],
        manifest.dig("x-hive", "mapping_recommendations")
      )
      assert_equal(
        HoneycombRegistry::CanonicalYAML.dump_manifest(manifest),
        File.binread(registry.package.manifest_path)
      )
      assert async_fix_git_success?(
        registry.root,
        "merge-base", "--is-ancestor", registry.source_revision, registry.release_revision
      )

      findings = HoneycombRegistry::Validator.validate(
        registry.package,
        hive_loader: -> { nil }
      )
      refute findings.errors?, findings.to_h.inspect
    end
  end

  private

  def load_workflow
    HoneycombRegistry::SafeYAML.load_file(File.join(CANDIDATE_ROOT, "workflow.yml"))
  end

  def stage(workflow, name)
    workflow.fetch("stages").find { |item| item.fetch("name") == name }
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

  def async_fix_git_success?(repository, *arguments)
    _stdout, _stderr, status = Open3.capture3("git", "-C", repository, *arguments)
    status.success?
  end
end
