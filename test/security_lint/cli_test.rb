# frozen_string_literal: true

require_relative "../test_helper"
require "json"

class SecurityLintCliTest < Minitest::Test
  SCRIPT = File.join(ROOT, "script", "honeycomb-security-lint")

  def test_help_and_invocation_errors_have_stable_exits
    stdout, stderr, status = capture_command(SCRIPT, "--help")
    assert_equal 0, status.exitstatus
    assert_includes stdout, "Usage: honeycomb-security-lint"
    assert_empty stderr

    _stdout, stderr, status = capture_command(SCRIPT)
    assert_equal 2, status.exitstatus
    assert_includes stderr, "--base SHA is required"
  end

  def test_waiting_state_writes_matching_artifact_comment_and_summary
    in_tmpdir do |dir|
      artifact = File.join(dir, "evidence.json")
      comment = File.join(dir, "comment.md")
      summary = File.join(dir, "summary.md")
      stdout, stderr, status = capture_command(
        SCRIPT, "--root", ROOT, "--base", "c" * 40, "--head", "d" * 40,
        "--pr", "42", "--event-action", "opened", "--gate", "required",
        "--run-id", "7", "--run-attempt", "1", "--repository", "hive-sh/honeycomb",
        "--output", artifact, "--comment-output", comment, "--summary-output", summary
      )

      assert_equal 1, status.exitstatus, stderr
      assert_empty stdout
      evidence = JSON.parse(File.read(artifact))
      assert_equal "awaiting_maintainer", evidence.fetch("state")
      assert_includes File.read(comment), "safe-to-validate"
      assert_includes File.read(summary), "safe-to-validate"
    end
  end

  def test_runs_the_production_validator_and_scanners_end_to_end
    in_tmpdir do |root|
      FileUtils.cp_r(File.join(ROOT, "lib"), root)
      FileUtils.cp_r(File.join(ROOT, "script"), root)
      FileUtils.cp_r(File.join(ROOT, "policy"), root)
      FileUtils.mkdir_p(File.join(root, "packages"))
      File.write(File.join(root, "packages", ".gitkeep"), "")
      git(root, "init", "-q")
      git(root, "config", "user.email", "test@example.test")
      git(root, "config", "user.name", "Test")
      git(root, "add", "lib", "script", "policy", "packages/.gitkeep")
      git(root, "commit", "-qm", "base")
      base = git(root, "rev-parse", "HEAD").strip

      honeycomb = install_valid_fixture(root)
      _stdout, stderr, status = capture_command(File.join(ROOT, "script", "honeycomb-manifest"), "--root", root, honeycomb)
      assert_equal 0, status.exitstatus, stderr
      git(root, "add", "packages")
      git(root, "commit", "-qm", "add honeycomb")
      head = git(root, "rev-parse", "HEAD").strip
      artifact = File.join(root, "evidence.json")

      _stdout, stderr, status = capture_command(
        SCRIPT, "--root", root, "--base", base, "--head", head, "--pr", "42",
        "--event-action", "labeled", "--gate", "applied", "--label-sha", head,
        "--run-id", "7", "--run-attempt", "1", "--repository", "hive-sh/honeycomb",
        "--output", artifact
      )

      assert_equal 0, status.exitstatus, stderr
      evidence = JSON.parse(File.read(artifact))
      assert_equal "pass", evidence.fetch("state")
      assert_equal "example", evidence.dig("packages", 0, "identity", "name")
      assert_equal 0, evidence.dig("totals", "hard")
    end
  end

  private

  def git(root, *arguments)
    stdout, stderr, status = Open3.capture3("git", *arguments, chdir: root)
    assert status.success?, stderr
    stdout
  end
end
