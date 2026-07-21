# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "honeycomb_security_lint"
require "json"
require "openssl"
require "psych"
require "shellwords"
require File.join(ROOT, "packages", "video-production", "0.1.0", "tools", "video-production")

class VideoProductionPackageTest < Minitest::Test
  PACKAGE_ROOT = File.join(ROOT, "packages", "video-production", "0.1.0")
  SHARED_TOOL = File.join(PACKAGE_ROOT, "tools", "video-production.rb")
  TOOLS = {
    "approval-template" => "video-approval-request.rb",
    "capture" => "video-capture.rb",
    "publish-ready" => "video-publish-ready.rb",
    "verify" => "video-verify.rb"
  }.freeze
  PREPARE_TOOL = File.join(PACKAGE_ROOT, "tools", "video-prepare.rb")
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
    tools/video-approval-request.rb
    tools/video-capture.rb
    tools/video-prepare.rb
    tools/video-production.rb
    tools/video-publish-ready.rb
    tools/video-verify.rb
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

    expected_wrappers = {
      "prepare" => "video-prepare.rb",
      "capture-approval" => "video-approval-request.rb",
      "capture" => "video-capture.rb",
      "verify" => "video-verify.rb",
      "editorial-approval" => "video-approval-request.rb",
      "publish-ready" => "video-publish-ready.rb"
    }
    expected_wrappers.each do |name, wrapper|
      permissions = stage(workflow, name).fetch("permissions")
      assert_equal "scoped", permissions.fetch("preset"), name
      bash_rules = permissions.fetch("tools").grep(/\ABash/)
      assert_equal ["Bash(*#{wrapper}*)"], bash_rules, name
      refute permissions.fetch("tools").any? { |tool| tool.match?(/Edit\(\.\/(?:capture|editorial)-approval/) }, name
      assert_empty permissions.fetch("tools").grep(/\AEdit/) if %w[capture-approval editorial-approval publish-ready].include?(name)
      if name == "capture"
        assert_equal ["Edit(./capture.md)"], permissions.fetch("tools").grep(/\AEdit/)
        refute permissions.fetch("tools").any? { |tool| tool.match?(/manifest|owner|tools\//i) }
      end
    end
    refute File.executable?(SHARED_TOOL), "shared implementation must not be a workflow executable"
  end

  def test_manifest_seed_declares_the_tool_inputs_and_registry_original_provenance
    manifest = Psych.safe_load_file(File.join(PACKAGE_ROOT, "manifest.yml"), permitted_classes: [], aliases: false)

    assert_equal "honeycomb-manifest/v1", manifest.fetch("schema")
    assert_equal "SOURCE_COMMIT_REQUIRED", manifest.dig("source", "revision")
    assert_equal 2, File.read(File.join(PACKAGE_ROOT, "manifest.yml")).scan("SOURCE_COMMIT_REQUIRED").length
    expected_tools = %w[
      tools/video-approval-request.rb
      tools/video-capture.rb
      tools/video-prepare.rb
      tools/video-publish-ready.rb
      tools/video-verify.rb
    ].map { |path| {"path" => path} }
    assert_equal expected_tools, manifest.dig("x-hive", "tools")
    assert_empty manifest.dig("x-hive", "prompt_assets")
    assert_equal OPTIONAL_INPUTS, manifest.dig("x-hive", "optional_inputs").map { |input| input.fetch("name") }
    assert_equal ["stages.capture"],
                 manifest.dig("x-hive", "optional_inputs").flat_map { |input| input.fetch("authorized_slots") }.uniq
    assert_equal "registry-original", manifest.dig("x-provenance", "kind")
    assert_equal SOURCE_PATHS, manifest.dig("x-provenance", "source_paths")
    expected_tools.each do |item|
      assert File.executable?(File.join(PACKAGE_ROOT, item.fetch("path"))), item.fetch("path")
    end
  end

  def test_ephemeral_two_commit_manifest_is_canonical_and_valid
    in_tmpdir do |registry|
      git!(registry, "init", "-q", "-b", "main")
      git!(registry, "config", "user.email", "video-production@example.test")
      git!(registry, "config", "user.name", "Video Production fixture")
      destination = File.join(registry, "packages", "video-production", "0.1.0")
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp_r(PACKAGE_ROOT, destination)
      git!(registry, "add", "packages")
      git!(registry, "commit", "-qm", "ephemeral behavior source")
      revision = git!(registry, "rev-parse", "HEAD").strip

      package = HoneycombRegistry::Package.new(destination, root: registry)
      seed = File.binread(package.manifest_path)
      assert_equal 2, seed.scan("SOURCE_COMMIT_REQUIRED").length
      File.binwrite(package.manifest_path, seed.gsub("SOURCE_COMMIT_REQUIRED", revision))
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
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
        env: {"PATH" => empty_bin}
      )
      refute status.success?
      assert_match(/missing host dependencies/i, stderr)
      failure = JSON.parse(File.read(File.join(approval.dig(:request, "take_path"), "failure.json")))
      assert_equal "capture-preflight", failure.fetch("step")
      assert_equal true, failure.fetch("retry_allowed")
    end

    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      # The signed request binds a private staged tree, so later source drift is
      # irrelevant to execution and the original snapshot may disappear.
      FileUtils.rm_rf(File.join(directory, "snapshot"))
      fake_bin = install_fake_tools(directory)
      stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
        env: {"PATH" => fake_bin}
      )
      assert status.success?, stderr
      assert_equal "captured", JSON.parse(stdout).fetch("status")
    end

    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      FileUtils.rm_rf(File.join(directory, "snapshot"))
      _stdout, stderr, status = run_tool(
        "approval-template", "--manifest", manifest, "--scene", "demo", "--stage", "capture",
        "--output", File.join(directory, "capture-approval.md")
      )
      refute status.success?
      assert_match(/snapshot.*directory/i, stderr)
    end
  end

  def test_capture_rejects_a_checked_approval_for_a_different_fingerprint
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      File.write(approval.fetch(:approval), File.read(approval.fetch(:approval)).sub(
        /Fingerprint: sha256:[0-9a-f]{64}/, "Fingerprint: sha256:#{"b" * 64}"
      ))

      _stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
        env: {"PATH" => install_fake_tools(directory)}
      )
      refute status.success?
      assert_match(/owner receipt signature does not match/i, stderr)
      take = approval.dig(:request, "take_path")
      refute File.exist?(File.join(take, "capture-context.json"))
    end
  end

  def test_capture_refuses_to_allocate_through_a_symlinked_output_directory
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      escaped = File.join(directory, "escaped")
      FileUtils.mkdir_p(escaped)
      File.symlink(escaped, File.join(directory, "media"))

      _stdout, stderr, status = run_tool(
        "approval-template", "--manifest", manifest, "--scene", "demo", "--stage", "capture",
        "--output", File.join(directory, "capture-approval.md")
      )
      refute status.success?
      assert_match(/output path contains a symlink/i, stderr)
      assert_empty Dir.children(escaped)
    end
  end

  def test_capture_allocates_the_next_take_and_preserves_docker_failure_evidence
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      FileUtils.mkdir_p(File.join(directory, "media", "demo", "take-0001"))
      approval = checked_approval(directory, manifest, stage: "capture")
      fake_bin = install_fake_tools(directory)

      stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
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
        "capture", "--manifest", failed_manifest, "--scene", "demo",
        "--approval", failed_approval.fetch(:approval), "--receipt", failed_approval.fetch(:receipt),
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
      "missing" => {mutate: ->(take) { FileUtils.rm(File.join(take, "demo.gif")) }, error: /missing artifact/i},
      "empty" => {mutate: ->(take) { File.truncate(File.join(take, "demo.cast"), 0) }, error: /empty artifact/i},
      "unplayable" => {env: {"FAKE_FFPROBE_FAIL" => "1"}, error: /unplayable/i},
      "empty-streams" => {env: {"FAKE_EMPTY_STREAMS" => "1"}, error: /invalid ffprobe output/i},
      "odd" => {env: {"FAKE_WIDTH" => "1279"}, error: /even dimensions/i},
      "wrong-codec" => {env: {"FAKE_CODEC" => "vp9"}, error: /codec.*h264/i},
      "wrong-pixel-format" => {env: {"FAKE_PIXEL_FORMAT" => "yuv444p"}, error: /pixel format.*yuv420p/i},
      "zero-duration" => {env: {"FAKE_DURATION" => "0"}, error: /duration must be positive/i}
    }

    scenarios.each do |name, scenario|
      in_tmpdir do |directory|
        manifest = write_media_project(directory)
        fake_bin = install_fake_tools(directory)
        capture = capture_take(directory, manifest, env: {"PATH" => fake_bin})
        take = capture.fetch("take_path")
        scenario[:mutate]&.call(take)
        environment = {"PATH" => fake_bin}.merge(scenario.fetch(:env, {}))
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
      fake_bin = install_fake_tools(directory)
      capture = capture_take(directory, manifest, env: {"PATH" => fake_bin})
      take = capture.fetch("take_path")
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
        "--verification", File.join(take, "verification.json"),
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
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
      fake_bin = install_fake_tools(directory)
      take = capture_take(directory, manifest, env: {"PATH" => fake_bin}).fetch("take_path")
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
        "--verification", verification,
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt)
      )
      refute status.success?
      assert_match(/artifact hash does not match.*mp4/i, stderr)
      refute File.exist?(File.join(take, "publish-ready.json"))
    end
  end

  def test_owner_receipt_is_required_and_only_the_exact_owner_sentence_authorizes
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = File.join(directory, "capture-approval.md")
      stdout, stderr, status = run_tool(
        "approval-template", "--manifest", manifest, "--scene", "demo", "--stage", "capture",
        "--output", approval
      )
      assert status.success?, stderr
      request = JSON.parse(stdout)
      receipt = File.join(directory, "capture-approval.sig")
      File.binwrite(receipt, "agent-minted-not-a-signature")
      activity = File.join(directory, "activity.log")

      _stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval, "--receipt", receipt,
        env: {"PATH" => install_fake_tools(directory), "FAKE_ACTIVITY_LOG" => activity}
      )
      refute status.success?
      assert_match(/owner receipt signature does not match/i, stderr)
      refute File.exist?(activity)
      refute File.exist?(File.join(request.fetch("take_path"), "capture-context.json"))

      File.write(approval, File.read(approval) + "\n  - [x] unrelated nested checkbox\n")
      key = (@owner_keys ||= {}).fetch(manifest)
      File.binwrite(receipt, key.sign(nil, File.binread(approval)))
      _stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval, "--receipt", receipt,
        env: {"PATH" => install_fake_tools(directory)}
      )
      refute status.success?
      assert_match(/exact capture owner approval sentence is not checked/i, stderr)
    end

    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      data = JSON.parse(File.read(manifest))
      private_key = File.join(directory, "owner-private.pem")
      File.write(private_key, (@owner_keys ||= {}).fetch(manifest).private_to_pem)
      data.fetch("capture")["owner_public_key"] = "owner-private.pem"
      File.write(manifest, JSON.pretty_generate(data))
      _stdout, stderr, status = run_tool("dry-run", "--manifest", manifest, "--scene", "demo")
      refute status.success?
      assert_match(/must not contain private key material/i, stderr)
    end

    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      data = JSON.parse(File.read(manifest))
      private_key = File.join(directory, "owner-private.der")
      File.binwrite(private_key, (@owner_keys ||= {}).fetch(manifest).private_to_der)
      data.fetch("capture")["owner_public_key"] = "owner-private.der"
      File.write(manifest, JSON.pretty_generate(data))
      _stdout, stderr, status = run_tool("dry-run", "--manifest", manifest, "--scene", "demo")
      refute status.success?
      assert_match(/must not contain private key material/i, stderr)
    end
  end

  def test_signed_approval_must_be_the_exact_canonical_human_readable_request
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = File.join(directory, "capture-approval.md")
      receipt = File.join(directory, "capture-approval.sig")
      stdout, stderr, status = run_tool(
        "approval-template", "--manifest", manifest, "--scene", "demo", "--stage", "capture",
        "--output", approval
      )
      assert status.success?, stderr
      request = File.read(approval)
      take_path = JSON.parse(stdout).fetch("take_path")
      contradictory = request.sub(
        "Image: #{IMAGE}", "Image: trusted.example/benign@sha256:#{"b" * 64}"
      ).sub("- [ ] I approve", "- [x] I approve")
      File.write(approval, contradictory)
      File.binwrite(receipt, (@owner_keys ||= {}).fetch(manifest).sign(nil, File.binread(approval)))
      activity = File.join(directory, "activity.log")
      _stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval, "--receipt", receipt,
        env: {"PATH" => install_fake_tools(directory), "FAKE_ACTIVITY_LOG" => activity}
      )
      refute status.success?
      assert_match(/canonical owner request/i, stderr)
      refute File.exist?(activity)
      assert_includes request, "Network: none"
      assert_includes request, "Take-Path: #{take_path}"
    end
  end

  def test_capture_binds_a_private_staged_snapshot_tree_and_empty_directories
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      first, first_error, first_status = run_tool("dry-run", "--manifest", manifest, "--scene", "demo")
      assert first_status.success?, first_error
      FileUtils.mkdir_p(File.join(directory, "snapshot", "empty-behavior-directory"))
      second, second_error, second_status = run_tool("dry-run", "--manifest", manifest, "--scene", "demo")
      assert second_status.success?, second_error
      refute_equal JSON.parse(first).fetch("snapshot_sha256"), JSON.parse(second).fetch("snapshot_sha256")

      approval = checked_approval(directory, manifest, stage: "capture")
      staged = approval.dig(:request, "staged_snapshot_path")
      assert File.directory?(staged)
      File.write(File.join(directory, "snapshot", "README.md"), "source changed after owner approval\n")
      activity = File.join(directory, "activity.log")
      stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
        env: {
          "PATH" => install_fake_tools(directory), "FAKE_ACTIVITY_LOG" => activity,
          "FAKE_CONTAINER_STATE" => File.join(directory, "container.state")
        }
      )
      assert status.success?, stderr
      assert_equal approval.dig(:request, "take_path"), JSON.parse(stdout).fetch("take_path")
      activity_text = File.read(activity)
      assert_includes activity_text, "#{staged}:/workspace:ro"
      refute_includes activity_text, "#{File.join(directory, "snapshot")}:/workspace:ro"
    end

    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      staged_file = File.join(approval.dig(:request, "staged_snapshot_path"), "README.md")
      FileUtils.chmod(0o600, staged_file)
      File.write(staged_file, "tampered staged tree\n")
      _stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
        env: {"PATH" => install_fake_tools(directory)}
      )
      refute status.success?
      assert_match(/staged snapshot hash does not match/i, stderr)
    end
  end

  def test_snapshot_and_output_must_be_disjoint_directories
    %w[snapshot snapshot/media .].each do |output_dir|
      in_tmpdir do |directory|
        manifest = write_media_project(directory)
        data = JSON.parse(File.read(manifest))
        data["output_dir"] = output_dir
        File.write(manifest, JSON.pretty_generate(data))
        _stdout, stderr, status = run_tool("dry-run", "--manifest", manifest, "--scene", "demo")
        refute status.success?, output_dir
        assert_match(/snapshot and output.*overlap/i, stderr, output_dir)
        refute File.exist?(File.join(directory, "snapshot", "media")), output_dir
      end
    end

    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      FileUtils.rm_rf(File.join(directory, "snapshot"))
      File.write(File.join(directory, "snapshot"), "single file\n")
      _stdout, stderr, status = run_tool("dry-run", "--manifest", manifest, "--scene", "demo")
      refute status.success?
      assert_match(/snapshot must be a non-symlink directory/i, stderr)
    end
  end

  def test_verify_rejects_synthetic_running_and_failed_takes
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      take = write_take(directory, mode: :valid)
      stdout, stderr, status = run_tool(
        "verify", "--manifest", manifest, "--scene", "demo", "--take", take,
        env: {"PATH" => install_fake_tools(directory)}
      )
      refute status.success?
      assert_empty stderr
      assert_match(/capture context is missing/i, JSON.parse(stdout).fetch("errors").join("; "))
      assert File.exist?(File.join(take, "verification.json"))
    end

    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      fake_bin = install_fake_tools(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      _stdout, _stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
        env: {"PATH" => fake_bin, "FAKE_FFMPEG_FAIL" => "1"}
      )
      refute status.success?
      take = approval.dig(:request, "take_path")
      File.binwrite(File.join(take, "demo.mp4"), "playable-looking replacement")
      stdout, stderr, status = run_tool(
        "verify", "--manifest", manifest, "--scene", "demo", "--take", take,
        env: {"PATH" => fake_bin}
      )
      refute status.success?
      assert_empty stderr
      errors = JSON.parse(stdout).fetch("errors").join("; ")
      assert_match(/failed capture evidence|capture context.*captured/i, errors)
    end
  end

  def test_capture_timeout_is_bounded_truncated_and_cleans_the_exact_container
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      data = JSON.parse(File.read(manifest))
      data.fetch("capture")["timeout_seconds"] = 1
      File.write(manifest, JSON.pretty_generate(data))
      approval = checked_approval(directory, manifest, stage: "capture")
      fake_bin = install_fake_tools(directory)
      activity = File.join(directory, "activity.log")
      state = File.join(directory, "container.state")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      _stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
        env: {
          "PATH" => fake_bin, "FAKE_ACTIVITY_LOG" => activity, "FAKE_CONTAINER_STATE" => state,
          "FAKE_ASCIINEMA_SLEEP" => "10", "FAKE_IGNORE_TERM" => "1", "FAKE_PIPE_HOLDER" => "1"
        }
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      refute status.success?
      assert_match(/asciinema failed/i, stderr)
      assert_operator elapsed, :<, 6
      failure = JSON.parse(File.read(File.join(approval.dig(:request, "take_path"), "failure.json")))
      assert_equal true, failure.fetch("timed_out")
      assert_equal "complete", failure.dig("container_cleanup", "status")
      assert_equal true, failure.fetch("process_cleanup_incomplete")
      assert_equal false, failure.fetch("retry_allowed")
      assert_match(/owner intervention/i, failure.fetch("recovery"))
      refute File.exist?(state)
      assert_match(/docker rm -f c{64}/, File.read(activity))
    end

    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      fake_bin = install_fake_tools(directory)
      _stdout, _stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
        env: {"PATH" => fake_bin, "FAKE_DOCKER_FAIL" => "1", "FAKE_OUTPUT_BYTES" => "1000000"}
      )
      refute status.success?
      log = File.read(File.join(approval.dig(:request, "take_path"), "capture.log"))
      assert_operator log.bytesize, :<, 200_000
      assert_includes log, "output truncated"
    end

    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      fake_bin = install_fake_tools(directory)
      _stdout, _stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
        env: {
          "PATH" => fake_bin, "FAKE_ASCIINEMA_FAIL" => "1",
          "FAKE_DOCKER_DISAPPEAR_AFTER_RM" => "1"
        }
      )
      refute status.success?
      failure = JSON.parse(File.read(File.join(approval.dig(:request, "take_path"), "failure.json")))
      assert_equal "incomplete", failure.dig("container_cleanup", "status")
      assert_equal false, failure.dig("container_cleanup", "absent")
      assert_equal false, failure.fetch("retry_allowed")
    end

    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      fake_bin = install_fake_tools(directory)
      _stdout, _stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
        env: {
          "PATH" => fake_bin, "FAKE_ASCIINEMA_FAIL" => "1",
          "FAKE_DOCKER_CLEANUP_FAIL" => "1", "FAKE_DOCKER_INSPECT_ERROR" => "1"
        }
      )
      refute status.success?
      failure = JSON.parse(File.read(File.join(approval.dig(:request, "take_path"), "failure.json")))
      assert_equal "incomplete", failure.dig("container_cleanup", "status")
      assert_equal false, failure.dig("container_cleanup", "absent")
      assert_equal false, failure.fetch("retry_allowed")
    end

    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      fake_bin = install_fake_tools(directory)
      _stdout, _stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
        env: {
          "PATH" => fake_bin, "FAKE_ASCIINEMA_FAIL" => "1",
          "FAKE_DOCKER_CLEANUP_FAIL" => "1", "FAKE_DOCKER_NO_SUCH" => "1"
        }
      )
      refute status.success?
      failure = JSON.parse(File.read(File.join(approval.dig(:request, "take_path"), "failure.json")))
      assert_equal "complete", failure.dig("container_cleanup", "status")
      assert_equal true, failure.dig("container_cleanup", "absent")
      assert_equal true, failure.fetch("retry_allowed")
    end
  end

  def test_successful_group_leader_cannot_leave_live_process_group_children
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      fake_bin = install_fake_tools(directory)
      child_pid_file = File.join(directory, "group-child.pid")
      stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
        env: {"PATH" => fake_bin, "FAKE_GROUP_CHILD_PID_FILE" => child_pid_file}
      )
      assert status.success?, stderr
      assert_equal "captured", JSON.parse(stdout).fetch("status")
      Timeout.timeout(3) { sleep 0.02 until File.exist?(child_pid_file) }
      child_pid = Integer(File.read(child_pid_file))
      Timeout.timeout(3) do
        loop do
          Process.kill(0, child_pid)
          sleep 0.02
        rescue Errno::ESRCH
          break
        end
      end
    ensure
      begin
        Process.kill("KILL", child_pid) if child_pid
      rescue Errno::ESRCH
        nil
      end
    end
  end

  def test_interrupt_and_post_allocation_spawn_failure_preserve_recovery_evidence
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      fake_bin = install_fake_tools(directory)
      state = File.join(directory, "container.state")
      pid_file = File.join(directory, "child.pid")
      command = [
        RbConfig.ruby, File.join(PACKAGE_ROOT, "tools", "video-capture.rb"),
        "--manifest", manifest, "--scene", "demo", "--approval", approval.fetch(:approval),
        "--receipt", approval.fetch(:receipt)
      ]
      environment = {
        "PATH" => fake_bin, "FAKE_CONTAINER_STATE" => state,
        "FAKE_ASCIINEMA_SLEEP" => "10", "FAKE_CHILD_PID_FILE" => pid_file
      }
      stdin, stdout, stderr, wait = Open3.popen3(environment, *command)
      stdin.close
      Timeout.timeout(4) { sleep 0.02 until File.exist?(pid_file) }
      Process.kill("INT", wait.pid)
      status = Timeout.timeout(6) { wait.value }
      stdout.read
      stderr.read
      assert_equal 130, status.exitstatus
      failure = JSON.parse(File.read(File.join(approval.dig(:request, "take_path"), "failure.json")))
      assert_equal true, failure.fetch("interrupted")
      assert_equal "complete", failure.dig("container_cleanup", "status")
      refute File.exist?(state)
      assert_raises(Errno::ESRCH) { Process.kill(0, Integer(File.read(pid_file))) }
    ensure
      stdout&.close
      stderr&.close
    end

    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      fake_bin = install_fake_tools(directory)
      _stdout, stderr, status = run_tool(
        "capture", "--manifest", manifest, "--scene", "demo",
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
        env: {
          "PATH" => fake_bin, "FAKE_ASCIINEMA_PATH" => File.join(fake_bin, "asciinema"),
          "FAKE_REMOVE_ASCIINEMA" => "1"
        }
      )
      refute status.success?
      assert_match(/asciinema failed/i, stderr)
      failure = JSON.parse(File.read(File.join(approval.dig(:request, "take_path"), "failure.json")))
      assert_equal "asciinema", failure.fetch("step")
      assert_match(/ENOENT|EACCES|permission/i, failure.fetch("error"))
    end

    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      approval = checked_approval(directory, manifest, stage: "capture")
      arguments = [
        "--manifest", manifest, "--scene", "demo",
        "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt)
      ]
      fake_bin = install_fake_tools(directory)
      status = nil
      _stdout, _stderr = capture_io do
        with_env("PATH" => fake_bin) do
          original_cp = FileUtils.method(:cp)
          FileUtils.define_singleton_method(:cp) { |*_args, **_kwargs| raise Interrupt }
          begin
            status = HiveVideoProduction::CLI.run(["capture", *arguments], allowed_commands: ["capture"])
          rescue Interrupt
            status = :escaped_interrupt
          ensure
            FileUtils.define_singleton_method(:cp, original_cp)
          end
        end
      end
      assert_equal 130, status
      failure = JSON.parse(File.read(File.join(approval.dig(:request, "take_path"), "failure.json")))
      assert_equal true, failure.fetch("interrupted")
      assert_equal "capture-initialize", failure.fetch("step")
      assert_equal "not-created", failure.dig("container_cleanup", "status")
    end
  end

  def test_interrupt_while_capture_readers_start_terminates_the_process_group
    in_tmpdir do |directory|
      child_pid_file = File.join(directory, "reader-start-child.pid")
      child_script = <<~RUBY
        File.write(ARGV.fetch(0), Process.pid)
        loop { sleep 1 }
      RUBY
      original_bounded_reader = HiveVideoProduction.method(:bounded_reader)
      HiveVideoProduction.define_singleton_method(:bounded_reader) do |_io|
        Timeout.timeout(3) { sleep 0.02 until File.exist?(child_pid_file) }
        raise Interrupt
      end

      result = HiveVideoProduction.send(
        :process_capture,
        [RbConfig.ruby, "-e", child_script, child_pid_file],
        timeout_seconds: 5
      )

      assert_equal true, result.fetch(:interrupted)
      assert_equal false, result.fetch(:cleanup_incomplete)
      child_pid = Integer(File.read(child_pid_file))
      assert_raises(Errno::ESRCH) { Process.kill(0, child_pid) }
    ensure
      HiveVideoProduction.define_singleton_method(:bounded_reader, original_bounded_reader) if original_bounded_reader
      begin
        Process.kill("KILL", child_pid) if child_pid
      rescue Errno::ESRCH
        nil
      end
    end
  end

  def test_approval_template_accepts_equals_form_and_mixed_option_order
    in_tmpdir do |directory|
      manifest = write_media_project(directory)
      fake_bin = install_fake_tools(directory)
      take = capture_take(directory, manifest, env: {"PATH" => fake_bin}).fetch("take_path")
      stdout, stderr, status = run_tool(
        "verify", "--manifest", manifest, "--scene", "demo", "--take", take,
        env: {"PATH" => fake_bin}
      )
      assert status.success?, stderr
      verification = File.join(take, "verification.json")
      output = File.join(directory, "editorial-equals.md")
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, File.join(PACKAGE_ROOT, "tools", "video-approval-request.rb"),
        "--output=#{output}", "--scene", "demo", "--stage=editorial",
        "--manifest=#{manifest}", "--verification=#{verification}"
      )
      assert status.success?, stderr
      assert_equal "editorial", JSON.parse(stdout).fetch("stage")
      assert File.exist?(output)
    end
  end

  def test_manifest_path_normalization_rejects_ambiguous_paths_without_activity
    values = ["/absolute", "../escape", "./snapshot", "snapshot//nested", "snapshot\\nested", "bad\0path"]
    %w[output_dir snapshot owner_public_key].product(values).each do |field, value|
      in_tmpdir do |directory|
        manifest = write_media_project(directory)
        data = JSON.parse(File.read(manifest))
        field == "output_dir" ? data[field] = value : data.fetch("capture")[field] = value
        File.write(manifest, JSON.generate(data))
        activity = File.join(directory, "activity.log")
        _stdout, stderr, status = run_tool(
          "dry-run", "--manifest", manifest, "--scene", "demo",
          env: {"PATH" => install_fake_tools(directory), "FAKE_ACTIVITY_LOG" => activity}
        )
        refute status.success?, "#{field}=#{value.inspect}"
        assert_match(/normalized relative path/i, stderr, "#{field}=#{value.inspect}")
        refute File.exist?(activity)
        refute File.exist?(File.join(directory, "media"))
      end
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

  def with_env(values)
    previous = values.to_h { |name, _value| [name, ENV[name]] }
    values.each { |name, value| ENV[name] = value }
    yield
  ensure
    previous.each do |name, value|
      value.nil? ? ENV.delete(name) : ENV[name] = value
    end
  end

  def run_tool(*arguments, env: {}, chdir: ROOT)
    command = arguments.shift
    tool, forwarded = case command
                      when "--help"
                        [SHARED_TOOL, [command]]
                      when "validate", "dry-run"
                        [PREPARE_TOOL, [command, *arguments]]
                      else
                        filename = TOOLS.fetch(command)
                        [File.join(PACKAGE_ROOT, "tools", filename), arguments]
                      end
    Open3.capture3(env, RbConfig.ruby, tool, *forwarded, chdir: chdir)
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
    owner_key = OpenSSL::PKey.generate_key("ED25519")
    public_key = File.join(directory, "owner-public.pem")
    File.write(public_key, owner_key.public_to_pem)
    (@owner_keys ||= {})[File.join(directory, "media-manifest.json")] = owner_key
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
        "owner_public_key" => "owner-public.pem",
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
    receipt = File.join(directory, "#{stage}-approval.sig")
    arguments = [
      "approval-template", "--manifest", manifest, "--scene", "demo", "--stage", stage,
      "--output", approval
    ]
    arguments.concat(["--verification", verification]) if verification
    stdout, stderr, status = run_tool(*arguments)
    assert status.success?, stderr
    checked = File.read(approval).sub(
      "- [ ] I approve this exact #{stage} request as the repository owner.",
      "- [x] I approve this exact #{stage} request as the repository owner."
    )
    File.write(approval, checked)
    key = (@owner_keys ||= {}).fetch(manifest)
    File.binwrite(receipt, key.sign(nil, File.binread(approval)))
    {approval: approval, receipt: receipt, request: JSON.parse(stdout)}
  end

  def capture_take(directory, manifest, env: {})
    approval = checked_approval(directory, manifest, stage: "capture")
    stdout, stderr, status = run_tool(
      "capture", "--manifest", manifest, "--scene", "demo",
      "--approval", approval.fetch(:approval), "--receipt", approval.fetch(:receipt),
      env: env
    )
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def install_fake_tools(directory)
    bin = File.join(directory, "fake-bin")
    FileUtils.mkdir_p(bin)
    write_fake_tool(bin, "docker", <<~'RUBY')
      activity = ENV["FAKE_ACTIVITY_LOG"]
      File.open(activity, "a") { |file| file.puts("docker #{ARGV.join(" ")}") } if activity
      if ARGV[0, 2] == ["rm", "-f"]
        if ENV["FAKE_DOCKER_CLEANUP_FAIL"] == "1"
          warn "cleanup failed"
          exit 19
        end
        FileUtils.rm_f(ENV["FAKE_CONTAINER_STATE"]) if ENV["FAKE_CONTAINER_STATE"]
        FileUtils.chmod(0o644, __FILE__) if ENV["FAKE_DOCKER_DISAPPEAR_AFTER_RM"] == "1"
        puts ARGV.fetch(2)
        exit 0
      end
      if ARGV.first == "inspect"
        if ENV["FAKE_DOCKER_NO_SUCH"] == "1"
          warn "Error: No such object: #{ARGV.fetch(1)}"
          exit 1
        end
        if ENV["FAKE_DOCKER_INSPECT_ERROR"] == "1"
          warn "permission denied while contacting Docker daemon"
          exit 1
        end
        if File.exist?(ENV.fetch("FAKE_CONTAINER_STATE", "/nonexistent"))
          puts JSON.generate("Id" => ARGV.fetch(1))
          exit 0
        end
        warn "Error: No such object: #{ARGV.fetch(1)}"
        exit 1
      end
      if ARGV[0, 2] == ["image", "inspect"] && ENV["FAKE_DOCKER_FAIL"] == "1"
        $stdout.write("x" * Integer(ENV.fetch("FAKE_OUTPUT_BYTES", "0")))
        warn "image unavailable"
        exit 17
      end
      if ARGV[0, 2] == ["image", "inspect"] && ENV["FAKE_ASCIINEMA_PATH"]
        FileUtils.chmod(0o644, ENV.fetch("FAKE_ASCIINEMA_PATH")) if ENV["FAKE_REMOVE_ASCIINEMA"] == "1"
      end
      puts "fake docker"
      puts ENV["VIDEO_CAPTURE_TOKEN"] if ENV["VIDEO_CAPTURE_TOKEN"]
    RUBY
    write_fake_tool(bin, "asciinema", <<~'RUBY')
      activity = ENV["FAKE_ACTIVITY_LOG"]
      File.open(activity, "a") { |file| file.puts("asciinema #{ARGV.join(" ")}") } if activity
      command = Shellwords.split(ARGV.fetch(ARGV.index("--command") + 1))
      cidfile = command.fetch(command.index("--cidfile") + 1)
      cid = "c" * 64
      File.write(cidfile, cid)
      File.write(ENV["FAKE_CONTAINER_STATE"], cid) if ENV["FAKE_CONTAINER_STATE"]
      File.write(ENV["FAKE_CHILD_PID_FILE"], Process.pid.to_s) if ENV["FAKE_CHILD_PID_FILE"]
      trap("TERM", "IGNORE") if ENV["FAKE_IGNORE_TERM"] == "1"
      if ENV["FAKE_PIPE_HOLDER"] == "1"
        fork do
          Process.setsid
          sleep 10
        end
      end
      if ENV["FAKE_GROUP_CHILD_PID_FILE"]
        File.write(ARGV.fetch(-1), "{\"version\":2}\n[0.0,\"o\",\"demo\\r\\n\"]\n")
        fork do
          STDIN.reopen(File::NULL)
          STDOUT.reopen(File::NULL, "w")
          STDERR.reopen(File::NULL, "w")
          File.write(ENV.fetch("FAKE_GROUP_CHILD_PID_FILE"), Process.pid.to_s)
          sleep 10
        end
        exit 0
      end
      sleep Float(ENV["FAKE_ASCIINEMA_SLEEP"]) if ENV["FAKE_ASCIINEMA_SLEEP"]
      if ENV["FAKE_ASCIINEMA_FAIL"] == "1"
        warn "recording failed"
        exit 20
      end
      File.write(ARGV.fetch(-1), "{\"version\":2}\n[0.0,\"o\",\"demo\\r\\n\"]\n")
    RUBY
    write_fake_tool(bin, "agg", <<~'RUBY')
      activity = ENV["FAKE_ACTIVITY_LOG"]
      File.open(activity, "a") { |file| file.puts("agg #{ARGV.join(" ")}") } if activity
      exit 21 if ENV["FAKE_AGG_FAIL"] == "1"
      File.binwrite(ARGV.fetch(-1), "GIF89a-fake")
    RUBY
    write_fake_tool(bin, "ffmpeg", <<~'RUBY')
      activity = ENV["FAKE_ACTIVITY_LOG"]
      File.open(activity, "a") { |file| file.puts("ffmpeg #{ARGV.join(" ")}") } if activity
      exit 22 if ENV["FAKE_FFMPEG_FAIL"] == "1"
      File.binwrite(ARGV.fetch(-1), "fake-h264-mp4")
    RUBY
    write_fake_tool(bin, "ffprobe", <<~'RUBY')
      activity = ENV["FAKE_ACTIVITY_LOG"]
      File.open(activity, "a") { |file| file.puts("ffprobe #{ARGV.join(" ")}") } if activity
      if ENV["FAKE_FFPROBE_FAIL"] == "1"
        warn "not playable"
        exit 18
      end
      if ENV["FAKE_EMPTY_STREAMS"] == "1"
        puts JSON.generate("streams" => [], "format" => {"duration" => "1.0"})
        exit 0
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
    File.write(path, "#!#{RbConfig.ruby}\nrequire \"fileutils\"\nrequire \"json\"\nrequire \"shellwords\"\n#{body}")
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

  def git!(directory, *arguments)
    stdout, stderr, status = Open3.capture3("git", *arguments, chdir: directory)
    raise "git #{arguments.join(" ")} failed: #{stderr}" unless status.success?

    stdout
  end
end
