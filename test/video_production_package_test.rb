# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "honeycomb_security_lint"
require "json"
require "psych"

class VideoProductionPackageTest < Minitest::Test
  PACKAGE_ROOT = File.join(ROOT, "packages", "video-production", "0.1.0")
  TOOL = File.join(PACKAGE_ROOT, "tools", "video-production.rb")
  IMAGE = "example.test/video-capture@sha256:#{"a" * 64}"
  OPTIONAL_INPUTS = %w[
    VIDEO_CAPTURE_PASSWORD
    VIDEO_CAPTURE_TOKEN
    VIDEO_CAPTURE_USERNAME
  ].freeze
  SOURCE_PATHS = %w[
    DEPENDENCIES.md
    README.md
    workflow.yml
    instructions/capture-approval.md
    instructions/capture.md
    instructions/editorial-approval.md
    instructions/prepare.md
    instructions/publish-ready.md
    instructions/verify.md
    tools/video-production.rb
  ].freeze

  def test_workflow_is_agent_agnostic_and_has_the_approval_gated_topology
    workflow = load_workflow

    assert_equal "video-production", workflow.fetch("id")
    assert_equal %w[inbox prepare capture-approval capture verify editorial-approval publish-ready],
                 workflow.fetch("stages").map { |stage| stage.fetch("name") }
    assert_equal "publish-ready.json", stage(workflow, "publish-ready").fetch("deliverable")
    assert_empty recursive_keys(workflow) & %w[agent model effort]

    workflow.fetch("stages").select { |item| item.fetch("kind") == "agent" }.each do |actor|
      assert actor.key?("mapping_role"), actor.fetch("name")
      assert actor.key?("mapping_contract"), actor.fetch("name")
      assert actor.key?("permissions"), actor.fetch("name")
    end

    assert_equal "yolo", stage(workflow, "capture").fetch("permissions")
    %w[prepare capture-approval verify editorial-approval publish-ready].each do |name|
      permissions = stage(workflow, name).fetch("permissions")
      refute_equal "yolo", permissions, name
      assert_equal "scoped", permissions.fetch("preset"), name
      assert permissions.fetch("tools").any? { |tool| tool.start_with?("Bash(*video-production.rb") }, name
    end
  end

  def test_manifest_seed_declares_the_tool_inputs_and_registry_original_provenance
    manifest = Psych.safe_load_file(File.join(PACKAGE_ROOT, "manifest.yml"), permitted_classes: [], aliases: false)

    assert_equal "honeycomb-manifest/v1", manifest.fetch("schema")
    assert_equal "SOURCE_COMMIT_REQUIRED", manifest.dig("source", "revision")
    assert_equal 2, File.read(File.join(PACKAGE_ROOT, "manifest.yml")).scan("SOURCE_COMMIT_REQUIRED").length
    assert_equal [{"path" => "tools/video-production.rb"}], manifest.dig("x-hive", "tools")
    assert_empty manifest.dig("x-hive", "prompt_assets")
    assert_equal OPTIONAL_INPUTS, manifest.dig("x-hive", "optional_inputs").map { |input| input.fetch("name") }
    assert_equal ["stages.capture"],
                 manifest.dig("x-hive", "optional_inputs").flat_map { |input| input.fetch("authorized_slots") }.uniq
    assert_equal "registry-original", manifest.dig("x-provenance", "kind")
    assert_equal SOURCE_PATHS, manifest.dig("x-provenance", "source_paths")
    assert File.executable?(TOOL), "declared package tool must retain executable mode"
  end

  def test_ephemeral_two_commit_manifest_is_canonical_and_valid
    in_tmpdir do |registry|
      git!(registry, "init", "-q", "-b", "main")
      git!(registry, "config", "user.email", "video-production@example.test")
      git!(registry, "config", "user.name", "Video Production fixture")
      destination = File.join(registry, "packages", "video-production", "0.1.0")
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp_r(PACKAGE_ROOT, destination)
      FileUtils.rm_f(File.join(destination, "manifest.yml"))
      git!(registry, "add", "packages")
      git!(registry, "commit", "-qm", "ephemeral behavior source")
      revision = git!(registry, "rev-parse", "HEAD").strip

      package = HoneycombRegistry::Package.new(destination, root: registry)
      File.write(package.manifest_path, Psych.dump(manifest_metadata(revision)))
      generated = HoneycombRegistry::Manifest.generate(package)
      refute generated.findings.errors?, generated.findings.to_h.inspect
      validated = HoneycombRegistry::Validator.validate(package, hive_loader: -> { nil })
      refute validated.errors?, validated.to_h.inspect
      assert_equal HoneycombRegistry::CanonicalYAML.dump_manifest(generated.document),
                   File.binread(package.manifest_path)
      assert_equal revision, generated.document.dig("source", "revision")
      assert_equal "high", generated.document.dig("permissions", "risk")
      assert_equal SOURCE_PATHS, generated.document.dig("x-provenance", "source_paths")

      change_set = Struct.new(:root) do
        def between(_base, _head)
          HoneycombSecurityLint::ChangeSet::Result.new(
            version_roots: ["packages/video-production/0.1.0"], paths: [], existing_version_roots: []
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
        pull_request: 1, base_sha: revision, head_sha: revision,
        action: "labeled", gate: "applied", label_sha: revision,
        run_id: 1, run_attempt: 1, repository: "hive-sh/honeycomb"
      }
      lint = HoneycombSecurityLint::Runner.new(
        root: registry, context: context,
        policy_path: File.join(ROOT, "policy", "security-lint.yml"),
        change_set: change_set, validator: validator
      ).run
      assert_equal "pass", lint.evidence.fetch("state"), lint.json
      assert_empty lint.evidence.fetch("packages").fetch(0).fetch("suppressions")
    ensure
      FileUtils.chmod_R(0o700, registry) if registry && File.exist?(registry)
    end
  end

  def test_help_and_unknown_scene_are_clear
    stdout, stderr, status = run_tool("--help")
    assert status.success?, stderr
    %w[validate dry-run approval-template capture verify publish-ready].each do |command|
      assert_includes stdout, command
    end

    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      stdout, stderr, status = run_tool("dry-run", "--manifest", manifest, "--scene", "missing")
      refute status.success?
      assert_empty stdout
      assert_match(/unknown scene.*missing/i, stderr)
    end
  end

  def test_validate_and_dry_run_emit_stable_parseable_json_without_container_activity
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      fake_bin = install_fake_tools(directory)
      activity = File.join(directory, "activity.log")
      environment = {"PATH" => fake_bin, "FAKE_ACTIVITY_LOG" => activity}

      validate_stdout, validate_stderr, validate_status = run_tool(
        "validate", "--manifest", manifest, env: environment
      )
      assert validate_status.success?, validate_stderr
      validation = JSON.parse(validate_stdout)
      assert_equal "hive-video-production-validation/v1", validation.fetch("schema")
      assert_equal "valid", validation.fetch("status")
      assert_equal ["demo"], validation.fetch("scenes")
      assert_match(/\A[0-9a-f]{64}\z/, validation.fetch("manifest_sha256"))
      assert_match(/\A[0-9a-f]{64}\z/, validation.fetch("tool_sha256"))

      first, first_stderr, first_status = run_tool(
        "dry-run", "--manifest", manifest, "--scene", "demo", env: environment
      )
      second, second_stderr, second_status = run_tool(
        "dry-run", "--manifest", manifest, "--scene", "demo", env: environment
      )
      assert first_status.success?, first_stderr
      assert second_status.success?, second_stderr
      assert_equal first, second
      plan = JSON.parse(first)
      assert_equal "hive-video-production-dry-run/v1", plan.fetch("schema")
      assert_equal "take-0001", plan.fetch("take")
      assert_equal %w[cast gif log mp4], plan.fetch("artifacts").keys.sort
      refute File.exist?(activity), "dry-run must not invoke Docker or media commands"
      refute File.exist?(File.join(directory, "media")), "dry-run must not allocate a take"
    end
  end

  def test_manifest_shape_and_clip_boundaries_fail_closed
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      data = JSON.parse(File.read(manifest))
      data.fetch("scenes").first["duration_seconds"] = 0
      File.write(manifest, JSON.pretty_generate(data))

      stdout, stderr, status = run_tool("validate", "--manifest", manifest)
      refute status.success?
      assert_empty stdout
      assert_match(/duration_seconds.*between 1 and 3600/i, stderr)

      duplicate = JSON.pretty_generate(JSON.parse(File.read(write_media_project(directory))))
                      .sub("{", "{\n  \"project\": \"shadow-project\",")
      File.write(manifest, duplicate)
      stdout, stderr, status = run_tool("validate", "--manifest", manifest)
      refute status.success?
      assert_empty stdout
      assert_match(/duplicate JSON key.*project/i, stderr)
    end
  end

  def test_capture_requires_host_dependencies_and_a_present_snapshot
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      empty_bin = File.join(directory, "empty-bin")
      FileUtils.mkdir_p(empty_bin)

      _stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo", "--approval", approval,
        env: {"PATH" => empty_bin}
      )
      refute status.success?
      assert_match(/missing host dependencies/i, stderr)

      FileUtils.rm_rf(File.join(directory, "snapshot"))
      fake_bin = install_fake_tools(directory)
      _stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo", "--approval", approval,
        env: {"PATH" => fake_bin}
      )
      refute status.success?
      assert_match(/snapshot.*does not exist/i, stderr)
    end
  end

  def test_capture_rejects_a_checked_approval_for_a_different_fingerprint
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      File.write(approval, File.read(approval).sub(/Fingerprint: sha256:[0-9a-f]{64}/,
                                                   "Fingerprint: sha256:#{"b" * 64}"))

      _stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo", "--approval", approval,
        env: {"PATH" => install_fake_tools(directory)}
      )
      refute status.success?
      assert_match(/approval fingerprint does not match/i, stderr)
      refute File.exist?(File.join(directory, "media"))
    end
  end

  def test_capture_refuses_to_allocate_through_a_symlinked_output_directory
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      escaped = File.join(directory, "escaped")
      FileUtils.mkdir_p(escaped)
      File.symlink(escaped, File.join(directory, "media"))

      _stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo", "--approval", approval,
        env: {"PATH" => install_fake_tools(directory)}
      )
      refute status.success?
      assert_match(/output path contains a symlink/i, stderr)
      assert_empty Dir.children(escaped)
    end
  end

  def test_capture_allocates_the_next_take_and_preserves_docker_failure_evidence
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      FileUtils.mkdir_p(File.join(directory, "media", "demo", "take-0001"))
      fake_bin = install_fake_tools(directory)

      stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo", "--approval", approval,
        env: {"PATH" => fake_bin, "VIDEO_CAPTURE_TOKEN" => "capture-secret-value"}
      )
      assert status.success?, stderr
      result = JSON.parse(stdout)
      assert_equal "take-0002", File.basename(result.fetch("take_path"))
      %w[cast gif log mp4].each do |kind|
        assert_operator File.size(result.fetch("artifacts").fetch(kind)), :>, 0, kind
      end
      refute_includes File.read(result.fetch("artifacts").fetch("log")), "capture-secret-value"

      failed_manifest = write_media_project(File.join(directory, "failed"))
      failed_approval = checked_approval(File.join(directory, "failed"), failed_manifest, stage: "capture")
      stdout, stderr, status = run_tool(
        "capture", "--manifest", failed_manifest, "--scene", "demo", "--approval", failed_approval,
        env: {"PATH" => fake_bin, "FAKE_DOCKER_FAIL" => "1"}
      )
      refute status.success?
      assert_empty stdout
      assert_match(/docker image inspection failed/i, stderr)
      take = Dir[File.join(directory, "failed", "media", "demo", "take-*")].fetch(0)
      assert_operator File.size(File.join(take, "capture.log")), :>, 0
      failure = JSON.parse(File.read(File.join(take, "failure.json")))
      assert_equal "failed", failure.fetch("status")
      assert_equal "docker-image-inspect", failure.fetch("step")
    end
  end

  def test_verification_rejects_missing_empty_unplayable_odd_and_wrong_codec_media
    scenarios = {
      "missing" => {files: :missing, error: /missing artifact/i},
      "empty" => {files: :empty, error: /empty artifact/i},
      "unplayable" => {files: :valid, env: {"FAKE_FFPROBE_FAIL" => "1"}, error: /unplayable/i},
      "odd" => {files: :valid, env: {"FAKE_WIDTH" => "1279"}, error: /even dimensions/i},
      "wrong-codec" => {files: :valid, env: {"FAKE_CODEC" => "vp9"}, error: /codec.*h264/i},
      "wrong-pixel-format" => {files: :valid, env: {"FAKE_PIXEL_FORMAT" => "yuv444p"}, error: /pixel format.*yuv420p/i}
    }

    scenarios.each do |name, scenario|
      in_tmpdir do |directory|
        manifest = write_media_project(directory)
        take = write_take(directory, mode: scenario.fetch(:files))
        environment = {"PATH" => install_fake_tools(directory)}.merge(scenario.fetch(:env, {}))
        stdout, stderr, status = run_tool(
          "verify", "--manifest", manifest, "--scene", "demo", "--take", take,
          env: environment
        )

        refute status.success?, name
        assert_empty stderr, name
        result = JSON.parse(stdout)
        assert_equal "invalid", result.fetch("status"), name
        assert_match scenario.fetch(:error), result.fetch("errors").join("; "), name
        assert File.exist?(File.join(take, "verification.json")), name
      end
    end
  end

  def test_verified_media_records_hashes_and_publish_ready_never_runs_a_publication_command
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      take = write_take(directory, mode: :valid)
      fake_bin = install_fake_tools(directory)
      stdout, stderr, status = run_tool(
        "verify", "--manifest", manifest, "--scene", "demo", "--take", take,
        env: {"PATH" => fake_bin}
      )
      assert status.success?, stderr
      verification = JSON.parse(stdout)
      assert_equal "verified", verification.fetch("status")
      assert_equal %w[cast gif log mp4], verification.fetch("hashes").keys.sort
      verification.fetch("hashes").each_value { |digest| assert_match(/\A[0-9a-f]{64}\z/, digest) }
      assert_equal 1280, verification.dig("mp4", "width")
      assert_equal 720, verification.dig("mp4", "height")
      assert_equal "h264", verification.dig("mp4", "codec")
      assert_equal "yuv420p", verification.dig("mp4", "pixel_format")
      assert File.exist?(File.join(take, "hashes.json"))

      approval = checked_approval(
        directory, manifest, stage: "editorial", verification: File.join(take, "verification.json")
      )
      activity = File.join(directory, "terminal-activity.log")
      stdout, stderr, status = run_tool(
        "publish-ready", "--manifest", manifest, "--scene", "demo", "--take", take,
        "--verification", File.join(take, "verification.json"), "--approval", approval,
        env: {"PATH" => fake_bin, "FAKE_ACTIVITY_LOG" => activity}
      )
      assert status.success?, stderr
      terminal = JSON.parse(stdout)
      assert_equal "publish-ready", terminal.fetch("status")
      assert_equal false, terminal.fetch("published")
      refute File.exist?(activity), "publish-ready must not invoke any host command"
      assert_equal terminal, JSON.parse(File.read(File.join(take, "publish-ready.json")))
    end
  end

  def test_publish_ready_rejects_media_changed_after_verification_and_approval
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      take = write_take(directory, mode: :valid)
      fake_bin = install_fake_tools(directory)
      _stdout, stderr, status = run_tool(
        "verify", "--manifest", manifest, "--scene", "demo", "--take", take,
        env: {"PATH" => fake_bin}
      )
      assert status.success?, stderr
      verification = File.join(take, "verification.json")
      approval = checked_approval(directory, manifest, stage: "editorial", verification: verification)
      File.binwrite(File.join(take, "demo.mp4"), "changed-after-approval")

      _stdout, stderr, status = run_tool(
        "publish-ready", "--manifest", manifest, "--scene", "demo", "--take", take,
        "--verification", verification, "--approval", approval
      )
      refute status.success?
      assert_match(/artifact hash does not match.*mp4/i, stderr)
      refute File.exist?(File.join(take, "publish-ready.json"))
    end
  end

  def test_documentation_discloses_trusted_owner_boundary_and_no_private_harness_runtime
    readme = File.read(File.join(PACKAGE_ROOT, "README.md"))
    corpus = Dir[File.join(PACKAGE_ROOT, "{README.md,instructions/*.md,workflow.yml,tools/*}")]
             .sort.map { |path| File.read(path) }.join("\n")

    %w[docker asciinema agg ffmpeg ffprobe snapshot publish-ready].each do |term|
      assert_includes readme.downcase, term
    end
    assert_match(/trusted owner operation/i, readme)
    assert_match(/not an os sandbox/i, readme)
    assert_match(/runtime-only|runtime injected/i, readme)
    refute_match(%r{(?:^|/)hive-recording(?:/|$)}, corpus)
    refute_match(/docker\s+(?:build|pull|load)|credential.*(?:copy|bake)|\b(?:curl|wget)\b/i, corpus)
    assert_match(/does not upload, post, publish, merge, deploy, or release/i, readme)
  end

  private

  def run_tool(*arguments, env: {}, chdir: ROOT)
    Open3.capture3(env, RbConfig.ruby, TOOL, *arguments, chdir: chdir)
  end

  def load_workflow
    Psych.safe_load_file(File.join(PACKAGE_ROOT, "workflow.yml"), permitted_classes: [], aliases: false)
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

  def write_media_project(directory, snapshot: true)
    FileUtils.mkdir_p(directory)
    snapshot_path = File.join(directory, "snapshot")
    if snapshot
      FileUtils.mkdir_p(snapshot_path)
      File.write(File.join(snapshot_path, "README.md"), "hardened demo snapshot\n")
    end
    manifest = File.join(directory, "media-manifest.json")
    File.write(manifest, JSON.pretty_generate(
      "schema" => "hive-video-production/v1",
      "project" => "example-project",
      "output_dir" => "media",
      "capture" => {
        "image" => IMAGE,
        "snapshot" => "snapshot",
        "network" => "none",
        "timeout_seconds" => 30,
        "environment" => []
      },
      "scenes" => [
        {
          "id" => "demo",
          "title" => "Deterministic demo",
          "duration_seconds" => 90,
          "columns" => 120,
          "rows" => 36,
          "command" => ["printf", "hello from capture\\n"]
        }
      ]
    ))
    manifest
  end

  def checked_approval(directory, manifest, stage:, verification: nil)
    approval = File.join(directory, "#{stage}-approval.md")
    arguments = [
      "approval-template", "--manifest", manifest, "--scene", "demo", "--stage", stage,
      "--output", approval
    ]
    arguments.concat(["--verification", verification]) if verification
    _stdout, stderr, status = run_tool(*arguments)
    assert status.success?, stderr
    File.write(approval, File.read(approval).sub("- [ ]", "- [x]"))
    approval
  end

  def install_fake_tools(directory)
    bin = File.join(directory, "fake-bin")
    FileUtils.mkdir_p(bin)
    write_fake_tool(bin, "docker", <<~'RUBY')
      activity = ENV["FAKE_ACTIVITY_LOG"]
      File.open(activity, "a") { |file| file.puts("docker #{ARGV.join(" ")}") } if activity
      if ARGV[0, 2] == ["image", "inspect"] && ENV["FAKE_DOCKER_FAIL"] == "1"
        warn "image unavailable"
        exit 17
      end
      puts "fake docker"
      puts ENV["VIDEO_CAPTURE_TOKEN"] if ENV["VIDEO_CAPTURE_TOKEN"]
    RUBY
    write_fake_tool(bin, "asciinema", <<~'RUBY')
      activity = ENV["FAKE_ACTIVITY_LOG"]
      File.open(activity, "a") { |file| file.puts("asciinema #{ARGV.join(" ")}") } if activity
      File.write(ARGV.fetch(-1), "{\"version\":2}\n[0.0,\"o\",\"demo\\r\\n\"]\n")
    RUBY
    write_fake_tool(bin, "agg", <<~'RUBY')
      activity = ENV["FAKE_ACTIVITY_LOG"]
      File.open(activity, "a") { |file| file.puts("agg #{ARGV.join(" ")}") } if activity
      File.binwrite(ARGV.fetch(-1), "GIF89a-fake")
    RUBY
    write_fake_tool(bin, "ffmpeg", <<~'RUBY')
      activity = ENV["FAKE_ACTIVITY_LOG"]
      File.open(activity, "a") { |file| file.puts("ffmpeg #{ARGV.join(" ")}") } if activity
      File.binwrite(ARGV.fetch(-1), "fake-h264-mp4")
    RUBY
    write_fake_tool(bin, "ffprobe", <<~'RUBY')
      activity = ENV["FAKE_ACTIVITY_LOG"]
      File.open(activity, "a") { |file| file.puts("ffprobe #{ARGV.join(" ")}") } if activity
      if ENV["FAKE_FFPROBE_FAIL"] == "1"
        warn "not playable"
        exit 18
      end
      puts JSON.generate(
        "streams" => [{
          "codec_name" => ENV.fetch("FAKE_CODEC", "h264"),
          "pix_fmt" => ENV.fetch("FAKE_PIXEL_FORMAT", "yuv420p"),
          "width" => Integer(ENV.fetch("FAKE_WIDTH", "1280")),
          "height" => Integer(ENV.fetch("FAKE_HEIGHT", "720"))
        }],
        "format" => {"duration" => ENV.fetch("FAKE_DURATION", "90.0")}
      )
    RUBY
    bin
  end

  def write_fake_tool(directory, name, body)
    path = File.join(directory, name)
    File.write(path, "#!#{RbConfig.ruby}\nrequire \"json\"\n#{body}")
    FileUtils.chmod(0o755, path)
  end

  def write_take(directory, mode:)
    take = File.join(directory, "media", "demo", "take-0001")
    FileUtils.mkdir_p(take)
    paths = {
      "cast" => File.join(take, "demo.cast"),
      "gif" => File.join(take, "demo.gif"),
      "log" => File.join(take, "capture.log"),
      "mp4" => File.join(take, "demo.mp4")
    }
    case mode
    when :valid
      paths.each { |kind, path| File.binwrite(path, "#{kind}-evidence") }
    when :empty
      paths.each_value { |path| FileUtils.touch(path) }
    when :missing
      nil
    else
      raise "unknown take mode: #{mode}"
    end
    take
  end

  def manifest_metadata(revision)
    {
      "schema" => "honeycomb-manifest/v1",
      "name" => "video-production",
      "version" => "0.1.0",
      "description" => "Approval-gated deterministic terminal video capture and verification",
      "author" => {"name" => "Honeycomb Maintainers", "url" => "https://github.com/ivankuznetsov/honeycomb"},
      "license" => "MIT",
      "hive_min_version" => "0.6.0",
      "source" => {
        "url" => "https://example.test/honeycomb/tree/#{revision}/packages/video-production/0.1.0",
        "revision" => revision
      },
      "x-hive" => {
        "tools" => [{"path" => "tools/video-production.rb"}],
        "prompt_assets" => [],
        "optional_inputs" => OPTIONAL_INPUTS.map do |name|
          {"name" => name, "authorized_slots" => ["stages.capture"]}
        end
      },
      "x-provenance" => {"kind" => "registry-original", "source_paths" => SOURCE_PATHS},
      "x-security" => {"network_host_reasons" => {}, "suppressions" => []}
    }
  end

  def git!(directory, *arguments)
    stdout, stderr, status = Open3.capture3("git", *arguments, chdir: directory)
    raise "git #{arguments.join(" ")} failed: #{stderr}" unless status.success?

    stdout
  end
end
