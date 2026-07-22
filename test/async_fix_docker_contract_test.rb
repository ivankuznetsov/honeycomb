# frozen_string_literal: true

require_relative "test_helper"
require "json"
require_relative "fixtures/async-fix/validate_summary"

class AsyncFixDockerContractTest < Minitest::Test
  FIXTURE_ROOT = File.join(ROOT, "test", "fixtures", "async-fix")
  BIN_ROOT = File.join(FIXTURE_ROOT, "bin")

  def test_smoke_entrypoint_is_offline_read_only_and_revision_pinned
    script = File.join(ROOT, "test", "docker", "async_fix_smoke.sh")
    source = File.read(script)

    assert File.executable?(script)
    assert_includes source, "--network none"
    assert_includes source, "--pull=never"
    assert_includes source, "--cap-drop=ALL"
    assert_includes source, "--entrypoint /inputs/honeycomb/test/fixtures/async-fix/container_entry.sh"
    assert_includes source, "--cidfile"
    assert_includes source, "/usr/bin/timeout"
    assert_includes source, "git -C \"$source\" ls-files -z"
    assert_includes source, "ruby@sha256:7a61aa7fe86768830f65d8e12571fc115f381a54557c7c88619a5368b92a0474"
    assert_match(%r{/inputs/honeycomb:ro}, source)
    assert_match(%r{/inputs/hive:ro}, source)
    assert_includes source, "af22485f9b2bee27a7497dc138e5e58ab9725bde"
  end

  def test_default_deny_fixtures_reject_unexpected_provider_github_and_git_calls
    in_tmpdir do |tmpdir|
      environment = {
        "HOME" => File.join(tmpdir, "home"),
        "TMPDIR" => tmpdir,
        "PATH" => "#{BIN_ROOT}:/usr/bin:/bin"
      }
      FileUtils.mkdir_p(environment.fetch("HOME"))

      assert_denied(environment, File.join(BIN_ROOT, "deny"), "wrangler", "deploy")
      assert_denied(environment, File.join(BIN_ROOT, "gh"), "release", "create", "v9.9.9")
      assert_denied(environment, File.join(BIN_ROOT, "gh"), "pr", "create", "--draft", "--draft")
      assert_denied(
        environment,
        File.join(BIN_ROOT, "git"),
        "ls-remote", "https://example.invalid/acme/widgets.git"
      )

      log = File.readlines(File.join(tmpdir, "async-fix-smoke", "logs", "denied.jsonl"), chomp: true)
                .map { |line| JSON.parse(line) }
      assert_equal %w[deny gh gh git], log.map { |entry| entry.fetch("fixture") }
      assert log.all? { |entry| entry.fetch("exit_code") == 97 }
    end
  end

  def test_summary_validator_requires_every_proof_and_exact_metrics
    summary = valid_summary
    assert_equal summary, AsyncFixSummaryValidator.validate!(
      JSON.generate(summary),
      honeycomb_revision: "a" * 40,
      hive_revision: "b" * 40
    )

    summary.fetch("proofs").delete("daemon_pr_opened")
    error = assert_raises(RuntimeError) do
      AsyncFixSummaryValidator.validate!(
        JSON.generate(summary),
        honeycomb_revision: "a" * 40,
        hive_revision: "b" * 40
      )
    end
    assert_match(/required proofs/, error.message)
  end

  def test_git_shim_accepts_only_the_exact_managed_git_configuration
    in_tmpdir do |tmpdir|
      environment = {
        "HOME" => File.join(tmpdir, "home"),
        "TMPDIR" => tmpdir,
        "PATH" => "#{BIN_ROOT}:/usr/bin:/bin"
      }
      repository = File.join(tmpdir, "async-fix-smoke", "repository")
      FileUtils.mkdir_p(repository)
      system("/usr/bin/git", "-C", repository, "init", "-q", "-b", "main") or flunk("git init failed")

      stdout, stderr, status = Open3.capture3(
        environment,
        File.join(BIN_ROOT, "git"),
        "-C", repository,
        "-c", "credential.https://github.com.helper=!gh auth git-credential",
        "symbolic-ref", "--quiet", "--short", "HEAD"
      )
      assert status.success?, stderr
      assert_equal "main\n", stdout

      assert_denied(
        environment,
        File.join(BIN_ROOT, "git"),
        "-C", repository,
        "-c", "alias.escape=!sh -c true",
        "status"
      )
      assert_denied(
        environment,
        File.join(BIN_ROOT, "git"),
        "-C", repository,
        "config", "core.hooksPath", File.join(tmpdir, "hooks")
      )
      assert_denied(
        environment,
        File.join(BIN_ROOT, "git"),
        "-C", repository,
        "remote", "set-url", "origin", "git@example.invalid:widgets.git"
      )
      assert_denied(
        environment,
        File.join(BIN_ROOT, "git"),
        "-C", repository,
        "diff", "--ext-diff"
      )
    end
  end

  def test_codex_fixture_rejects_unknown_prompts_and_argv
    in_tmpdir do |tmpdir|
      root = File.join(tmpdir, "async-fix-smoke")
      repository = File.join(root, "repository")
      FileUtils.mkdir_p(repository)
      environment = {
        "HOME" => File.join(root, "home"),
        "TMPDIR" => tmpdir,
        "PATH" => "#{BIN_ROOT}:/usr/bin:/bin"
      }
      FileUtils.mkdir_p(environment.fetch("HOME"))
      base = %w[exec --dangerously-bypass-approvals-and-sandbox --json -]

      assert_codex_denied(environment, repository, base, "unrecognized orchestration prompt\n")
      assert_codex_denied(
        environment,
        repository,
        %w[exec --dangerously-bypass-approvals-and-sandbox --mystery --json -],
        "unrecognized orchestration prompt\n"
      )
    end
  end

  def test_path_guards_reject_symlink_escapes
    in_tmpdir do |tmpdir|
      root = File.join(tmpdir, "async-fix-smoke")
      outside = File.join(tmpdir, "outside")
      FileUtils.mkdir_p([root, outside])
      File.write(File.join(outside, "existing"), "outside\n")
      File.symlink(outside, File.join(root, "escape"))

      environment = {"HOME" => File.join(root, "home"), "TMPDIR" => tmpdir}
      FileUtils.mkdir_p(environment.fetch("HOME"))
      with_env(environment) do
        refute AsyncFixFixtureSupport.existing_within_root?(File.join(root, "escape", "existing"))
        refute AsyncFixFixtureSupport.writable_within_root?(File.join(root, "escape", "new"))
      end
    end
  end

  private

  def assert_denied(environment, *command)
    _stdout, stderr, status = Open3.capture3(environment, *command)

    assert_equal 97, status.exitstatus, [command, stderr].inspect
    assert_match(/default-deny|denied/i, stderr)
  end

  def assert_codex_denied(environment, chdir, argv, prompt)
    _stdout, stderr, status = Open3.capture3(
      environment,
      File.join(BIN_ROOT, "codex"), *argv,
      chdir: chdir,
      stdin_data: prompt
    )
    assert_equal 97, status.exitstatus, stderr
    assert_match(/default-deny/i, stderr)
  end

  def valid_summary
    {
      "schema" => AsyncFixSummaryValidator::SCHEMA,
      "ok" => true,
      "honeycomb_revision" => "a" * 40,
      "hive_revision" => "b" * 40,
      "ruby" => AsyncFixSummaryValidator::RUBY_VERSION,
      "proofs" => AsyncFixFixtureSupport::REQUIRED_PROOFS.to_h { |proof| [proof, true] },
      "metrics" => AsyncFixSummaryValidator::EXPECTED_METRICS.dup,
      "tasks" => %w[repair-one-260722-aaaa repair-two-260722-bbbb]
    }
  end

  def with_env(overrides)
    previous = overrides.to_h { |key, _value| [key, ENV[key]] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end
end
