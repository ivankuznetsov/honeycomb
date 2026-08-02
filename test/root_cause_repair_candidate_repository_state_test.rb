# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"

class RootCauseRepairCandidateRepositoryStateTest < Minitest::Test
  TOOL = File.join(
    ROOT, "candidates", "root-cause-repair", "tools", "repository-state.rb"
  )

  def test_linked_hive_state_and_unrelated_branches_do_not_invalidate_target
    with_linked_repository do |repository, state_root, task_folder|
      git!(repository, "branch", "task-to-remove")
      baseline = run_tool!(task_folder, "create")
      digest = baseline.dig("checkpoint", "digest")

      File.write(File.join(task_folder, "state-event.md"), "complete\n")
      git!(state_root, "add", ".")
      git!(state_root, "commit", "-qm", "advance Hive state")
      git!(repository, "branch", "concurrent-task")
      git!(repository, "branch", "-D", "task-to-remove")
      git!(repository, "update-ref", "refs/remotes/origin/observed", "HEAD")

      comparison = run_tool!(task_folder, "compare", "--expect", digest)
      assert_equal "continue", comparison.fetch("verdict")
      assert_equal "unrelated_refs", comparison.fetch("reason")
      assert_equal %w[
        refs/heads/concurrent-task
        refs/heads/hive/state
        refs/heads/task-to-remove
        refs/remotes/origin/observed
      ], comparison.dig("changes", "unrelated", "records").map { |entry| entry.fetch("name") }
      removed = comparison.dig("changes", "unrelated", "records").find do |entry|
        entry.fetch("name") == "refs/heads/task-to-remove"
      end
      assert_nil removed.fetch("after")
      refute_nil removed.fetch("before")
      assert_equal false, comparison.dig("changes", "unrelated", "truncated")
    end
  end

  def test_relevant_and_ambiguous_ref_changes_block
    with_linked_repository do |repository, _state_root, task_folder|
      digest = run_tool!(task_folder, "create").dig("checkpoint", "digest")
      original = git!(repository, "rev-parse", "HEAD").strip
      advanced = git!(repository, "commit-tree", "HEAD^{tree}", "-p", original, "-m", "advance target").strip
      git!(repository, "update-ref", "refs/heads/main", advanced, original)

      relevant = run_tool!(task_folder, "compare", "--expect", digest)
      assert_equal "blocked", relevant.fetch("verdict")
      assert_equal "target_changed", relevant.fetch("reason")
      assert_equal ["refs/heads/main"], relevant.dig("changes", "relevant", "records").map { |entry| entry.fetch("name") }
    end

    with_linked_repository do |repository, _state_root, task_folder|
      digest = run_tool!(task_folder, "create").dig("checkpoint", "digest")
      git!(repository, "tag", "authority-ambiguous")

      ambiguous = run_tool!(task_folder, "compare", "--expect", digest)
      assert_equal "blocked", ambiguous.fetch("verdict")
      assert_equal "ambiguous_refs", ambiguous.fetch("reason")
      assert_equal ["refs/tags/authority-ambiguous"], ambiguous.dig("changes", "ambiguous", "records").map { |entry| entry.fetch("name") }
    end
  end

  def test_authorized_repair_advances_checkpoint_but_later_drift_blocks
    with_linked_repository do |_repository, _state_root, task_folder|
      target = File.expand_path("../../../..", task_folder)
      digest = run_tool!(task_folder, "create").dig("checkpoint", "digest")
      File.write(File.join(target, "tracked.txt"), "repaired\n")
      File.write(File.join(target, "regression_test.rb"), "assert true\n")

      before_advance = run_tool!(task_folder, "compare", "--expect", digest)
      assert_equal "blocked", before_advance.fetch("verdict")
      assert_equal "target_changed", before_advance.fetch("reason")

      advanced = run_tool!(task_folder, "advance", "--allow-worktree", "--expect", digest)
      assert_equal "continue", advanced.fetch("verdict")
      assert_equal "checkpoint_advanced", advanced.fetch("reason")
      refute_equal digest, advanced.dig("checkpoint", "digest")

      new_digest = advanced.dig("checkpoint", "digest")
      unchanged = run_tool!(task_folder, "compare", "--expect", new_digest)
      assert_equal "unchanged", unchanged.fetch("reason")

      File.write(File.join(target, "owner-change.txt"), "unexpected\n")
      drift = run_tool!(task_folder, "compare", "--expect", new_digest)
      assert_equal "blocked", drift.fetch("verdict")
      assert_equal "target_changed", drift.fetch("reason")
    end
  end

  def test_checkpoint_integrity_and_changed_ref_evidence_are_bounded
    with_linked_repository do |repository, _state_root, task_folder|
      digest = run_tool!(task_folder, "create").dig("checkpoint", "digest")
      75.times { |index| git!(repository, "branch", format("other-%03d", index)) }

      comparison = run_tool!(task_folder, "compare", "--expect", digest)
      assert_equal 75, comparison.dig("changes", "unrelated", "count")
      assert_equal 50, comparison.dig("changes", "unrelated", "records").length
      assert_equal true, comparison.dig("changes", "unrelated", "truncated")
      assert_match(/\Asha256:[0-9a-f]{64}\z/, comparison.dig("changes", "unrelated", "digest"))

      mismatch = run_tool(task_folder, "compare", "--expect", "sha256:#{'0' * 64}")
      refute mismatch.fetch(:status).success?
      assert_equal "checkpoint_mismatch", JSON.parse(mismatch.fetch(:stdout)).dig("error", "code")

      checkpoint = File.join(task_folder, "repository-authority.json")
      File.write(checkpoint, "{}\n")
      corrupt = run_tool(task_folder, "compare", "--expect", digest)
      refute corrupt.fetch(:status).success?
      assert_equal "checkpoint_invalid", JSON.parse(corrupt.fetch(:stdout)).dig("error", "code")

      outside = File.join(File.dirname(task_folder), "outside-checkpoint")
      File.write(outside, "{}\n")
      FileUtils.rm_f(checkpoint)
      File.symlink(outside, checkpoint)
      linked = run_tool(task_folder, "compare", "--expect", digest)
      refute linked.fetch(:status).success?
      assert_equal "checkpoint_invalid", JSON.parse(linked.fetch(:stdout)).dig("error", "code")
    end
  end

  def test_capture_retries_target_movement_once_but_not_unrelated_ref_movement
    with_linked_repository do |repository, _state_root, task_folder|
      marker = File.join(File.dirname(repository), "move-once")
      tool = instrumented_tool(repository, <<~RUBY)
        unless File.exist?(ENV.fetch("RACE_MARKER"))
          File.write(ENV.fetch("RACE_MARKER"), "moved")
          File.write(ENV.fetch("RACE_TARGET"), "moved during capture\\n")
        end
      RUBY
      report = run_custom_tool!(
        tool, task_folder, "create",
        "RACE_MARKER" => marker,
        "RACE_TARGET" => File.join(repository, "tracked.txt")
      )
      assert_equal 1, report.fetch("capture_retries")
      assert_equal "checkpoint_created", report.fetch("reason")
    end

    with_linked_repository do |repository, _state_root, task_folder|
      marker = File.join(File.dirname(repository), "unrelated-once")
      tool = instrumented_tool(repository, <<~RUBY)
        unless File.exist?(ENV.fetch("RACE_MARKER"))
          File.write(ENV.fetch("RACE_MARKER"), "moved")
          system("git", "-C", ENV.fetch("RACE_REPOSITORY"), "branch", "concurrent-during-capture") or abort
        end
      RUBY
      report = run_custom_tool!(
        tool, task_folder, "create",
        "RACE_MARKER" => marker,
        "RACE_REPOSITORY" => repository
      )
      assert_equal 0, report.fetch("capture_retries")
      assert_equal 1, report.dig("measurement", "count")
      assert_equal ["refs/heads/concurrent-during-capture"],
                   report.dig("measurement", "records").map { |entry| entry.fetch("name") }
    end
  end

  def test_repeated_target_movement_returns_state_changed_after_one_retry
    with_linked_repository do |repository, _state_root, task_folder|
      counter = File.join(File.dirname(repository), "move-count")
      tool = instrumented_tool(repository, <<~RUBY)
        count = File.exist?(ENV.fetch("RACE_COUNTER")) ? File.read(ENV.fetch("RACE_COUNTER")).to_i : 0
        File.write(ENV.fetch("RACE_COUNTER"), (count + 1).to_s)
        File.write(ENV.fetch("RACE_TARGET"), "movement \#{count}\\n")
      RUBY
      stdout, stderr, status = Open3.capture3(
        {
          "RACE_COUNTER" => counter,
          "RACE_TARGET" => File.join(repository, "tracked.txt")
        },
        tool, "create", chdir: task_folder
      )
      refute status.success?, stdout
      assert_empty stderr
      assert_equal "state_changed", JSON.parse(stdout).dig("error", "code")
      assert_equal "2", File.read(counter)
    end
  end

  def test_candidate_remains_manifest_free_and_does_not_mutate_released_package
    refute File.exist?(File.join(ROOT, "candidates", "root-cause-repair", "manifest.yml"))
    assert File.executable?(TOOL)
    assert_equal "honeycomb-repository-state/v2",
                 JSON.parse(Open3.capture3(TOOL, chdir: ROOT).first).fetch("schema")
    released = File.join(ROOT, "packages", "root-cause-repair", "1.0.0", "tools", "repository-state.rb")
    expected = git!(ROOT, "show", "HEAD:packages/root-cause-repair/1.0.0/tools/repository-state.rb")
    assert_equal expected, File.binread(released)
  end

  private

  def with_linked_repository
    Dir.mktmpdir("honeycomb-root-cause-candidate") do |directory|
      repository = File.join(directory, "target")
      FileUtils.mkdir_p(repository)
      git!(repository, "init", "-q", "-b", "main")
      git!(repository, "config", "user.name", "Candidate Test")
      git!(repository, "config", "user.email", "candidate@example.test")
      File.write(File.join(repository, ".gitignore"), ".hive-state/\n")
      File.write(File.join(repository, "tracked.txt"), "original\n")
      git!(repository, "add", ".")
      git!(repository, "commit", "-qm", "seed target")

      state_root = File.join(repository, ".hive-state")
      git!(repository, "worktree", "add", "-q", "-b", "hive/state", state_root, "HEAD")
      task_folder = File.join(state_root, "stages", "2-reproduce", "task")
      FileUtils.mkdir_p(task_folder)
      File.write(File.join(task_folder, "brief.md"), "fix the bug\n")
      git!(state_root, "add", ".")
      git!(state_root, "commit", "-qm", "seed Hive state")

      yield repository, state_root, task_folder
    ensure
      FileUtils.chmod_R(0o700, directory) if directory && File.exist?(directory)
    end
  end

  def run_tool!(task_folder, *arguments)
    result = run_tool(task_folder, *arguments)
    assert result.fetch(:status).success?, "#{result.fetch(:stderr)}\n#{result.fetch(:stdout)}"
    assert_empty result.fetch(:stderr)
    JSON.parse(result.fetch(:stdout))
  end

  def run_tool(task_folder, *arguments)
    stdout, stderr, status = Open3.capture3(TOOL, *arguments, chdir: task_folder)
    {stdout: stdout, stderr: stderr, status: status}
  end

  def run_custom_tool!(tool, task_folder, *arguments)
    environment = arguments.last.is_a?(Hash) ? arguments.pop : {}
    stdout, stderr, status = Open3.capture3(environment, tool, *arguments, chdir: task_folder)
    assert status.success?, "#{stderr}\n#{stdout}"
    assert_empty stderr
    JSON.parse(stdout)
  end

  def instrumented_tool(repository, injected_source)
    tool = File.join(File.dirname(repository), "repository-state-instrumented-#{injected_source.hash.abs}.rb")
    source = File.binread(TOOL)
    anchor = "    # A writer can change a path after its first read without moving HEAD,\n"
    raise "instrumentation anchor missing" unless source.include?(anchor)

    File.binwrite(tool, source.sub(anchor, injected_source.lines.map { |line| "    #{line}" }.join + anchor))
    File.chmod(0o755, tool)
    tool
  end

  def git!(repository, *arguments)
    stdout, stderr, status = Open3.capture3(
      {"GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0"},
      "git", "-c", "commit.gpgsign=false", "-C", repository, *arguments
    )
    assert status.success?, "git #{arguments.join(' ')} failed: #{stderr}\n#{stdout}"
    stdout
  end
end
