# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "json"
require "timeout"

class RepositoryStateToolTest < Minitest::Test
  TOOLS = %w[root-cause-repair reviewer-panel].to_h do |name|
    [name, File.join(ROOT, "candidates", name, "1.0.0", "tools", "repository-state.rb")]
  end.freeze

  def test_tools_are_byte_identical_executable_and_repeatable_without_mutation_or_disclosure
    assert_equal File.binread(TOOLS.fetch("root-cause-repair")), File.binread(TOOLS.fetch("reviewer-panel"))
    assert TOOLS.values.all? { |tool| File.executable?(tool) }

    with_repository do |repository, task_directory|
      secret = "super-secret-content-canary-7c715b"
      File.binwrite(File.join(repository, "secret.txt"), secret)
      git(repository, "add", "secret.txt")
      git(repository, "commit", "-qm", "add secret")
      before = filesystem_snapshot(repository)

      outputs = TOOLS.values.map do |tool|
        stdout, stderr, status = run_tool(tool, task_directory, "HONEYCOMB_SECRET_CANARY" => secret)
        assert status.success?, stderr
        refute_includes stdout, secret
        assert_empty stderr
        stdout
      end

      repeated, stderr, status = run_tool(TOOLS.fetch("root-cause-repair"), task_directory)
      assert status.success?, stderr
      assert_equal outputs.first, repeated
      assert_equal outputs.first, outputs.last
      assert_equal before, filesystem_snapshot(repository)

      report = JSON.parse(repeated)
      assert_equal "honeycomb-repository-state/v1", report.fetch("schema")
      assert_equal "ok", report.fetch("status")
      assert_match(/\Asha256:[0-9a-f]{64}\z/, report.fetch("fingerprint"))
      assert_equal "refs/heads/main", report.dig("head", "symbolic")
      assert_match(/\A[0-9a-f]{40,64}\z/, report.dig("head", "commit"))
    end
  end

  def test_every_git_significant_worktree_and_ref_change_alters_the_fingerprint
    with_repository do |repository, task_directory|
      fingerprints = [fingerprint(task_directory)]

      File.binwrite(File.join(repository, "tracked.txt"), "staged\n")
      git(repository, "add", "tracked.txt")
      fingerprints << fingerprint(task_directory)

      File.binwrite(File.join(repository, "tracked.txt"), "unstaged\n")
      fingerprints << fingerprint(task_directory)

      FileUtils.rm_f(File.join(repository, "delete-me.txt"))
      fingerprints << fingerprint(task_directory)

      git(repository, "mv", "rename-me.txt", "renamed.txt")
      fingerprints << fingerprint(task_directory)

      File.chmod(0o755, File.join(repository, "mode-me.sh"))
      fingerprints << fingerprint(task_directory)

      File.symlink("tracked.txt", File.join(repository, "link-to-tracked"))
      fingerprints << fingerprint(task_directory)

      File.binwrite(File.join(repository, "untracked.txt"), "untracked\n")
      fingerprints << fingerprint(task_directory)

      git(repository, "branch", "evidence-branch")
      fingerprints << fingerprint(task_directory)

      git(repository, "tag", "evidence-tag")
      fingerprints << fingerprint(task_directory)

      git(repository, "stash", "push", "-u", "-m", "evidence stash")
      fingerprints << fingerprint(task_directory)

      assert_equal fingerprints.length, fingerprints.uniq.length
    end
  end

  def test_ignored_files_and_hive_state_bytes_are_excluded
    with_repository do |repository, task_directory|
      before = fingerprint(task_directory)
      FileUtils.mkdir_p(File.join(repository, "ignored"))
      File.binwrite(File.join(repository, "ignored", "cache.bin"), "ignored one")
      File.binwrite(File.join(task_directory, "review.md"), "hive state one")
      assert_equal before, fingerprint(task_directory)

      File.binwrite(File.join(repository, "ignored", "cache.bin"), "ignored two")
      File.binwrite(File.join(task_directory, "review.md"), "hive state two")
      assert_equal before, fingerprint(task_directory)
    end
  end

  def test_unusual_path_bytes_and_symlink_targets_are_hashed_without_being_emitted
    with_repository do |repository, task_directory|
      odd_path = File.join(repository.b, "odd-\xFF-name".b)
      odd_content = "odd-content-canary-42"
      link_target = "target-canary-51"
      File.binwrite(odd_path, odd_content)
      File.symlink(link_target, File.join(repository, "odd-link"))

      stdout, stderr, status = run_tool(TOOLS.fetch("root-cause-repair"), task_directory)
      assert status.success?, stderr
      refute_includes stdout, odd_content
      refute_includes stdout, link_target
      refute_includes stdout, "odd-name"
      before = JSON.parse(stdout).fetch("fingerprint")

      File.binwrite(odd_path, "different")
      refute_equal before, fingerprint(task_directory)
    end
  end

  def test_non_git_and_non_hive_state_invocations_fail_with_structured_errors
    in_tmpdir do |directory|
      state_root = File.join(directory, ".hive-state")
      FileUtils.mkdir_p(state_root)
      git(state_root, "init", "-q")
      assert_error(state_root, "target_not_git")
    end

    with_repository do |repository, _task_directory|
      assert_error(repository, "state_root_invalid")
    end
  end

  def test_unreadable_oversized_and_special_entries_fail_closed
    with_repository do |repository, task_directory|
      unreadable = File.join(repository, "unreadable.txt")
      File.binwrite(unreadable, "cannot read")
      File.chmod(0, unreadable)
      begin
        assert_error(task_directory, "entry_unreadable") unless Process.uid.zero?
      ensure
        File.chmod(0o644, unreadable)
      end
      FileUtils.rm_f(unreadable)

      oversized = File.join(repository, "oversized.bin")
      File.binwrite(oversized, "")
      File.truncate(oversized, 16 * 1024 * 1024 + 1)
      assert_error(task_directory, "resource_limit")
      FileUtils.rm_f(oversized)

      fifo = File.join(repository, "unsupported.fifo")
      File.mkfifo(fifo)
      assert_error(task_directory, "entry_unsupported")
    end
  end

  def test_git_metadata_output_is_bounded_before_it_can_exhaust_memory
    with_repository do |repository, task_directory|
      32.times { |index| git(repository, "tag", "metadata-limit-#{index}-#{'x' * 48}") }
      limited_tool = File.join(File.dirname(repository), "repository-state-limited.rb")
      source = File.binread(TOOLS.fetch("root-cause-repair")).sub(
        "MAX_TOTAL_BYTES = 256 * 1024 * 1024",
        "MAX_TOTAL_BYTES = 1024"
      )
      File.binwrite(limited_tool, source)
      File.chmod(0o755, limited_tool)

      assert_error_with_tool(limited_tool, task_directory, "resource_limit")
    end
  end

  def test_non_default_index_flags_fail_closed
    with_repository do |repository, task_directory|
      [
        ["--assume-unchanged", "--no-assume-unchanged"],
        ["--skip-worktree", "--no-skip-worktree"]
      ].each do |set_flag, clear_flag|
        git(repository, "update-index", set_flag, "tracked.txt")
        assert_error(task_directory, "index_flags_unsupported")
        git(repository, "update-index", clear_flag, "tracked.txt")
      end

      git(repository, "config", "core.fsmonitor", "true")
      git(repository, "update-index", "--fsmonitor-valid", "tracked.txt")
      assert_error(task_directory, "index_flags_unsupported")
      git(repository, "update-index", "--no-fsmonitor-valid", "tracked.txt")
      git(repository, "config", "--unset", "core.fsmonitor")
      fingerprint(task_directory)
    end
  end

  def test_directory_walk_does_not_spawn_git_per_directory
    with_repository do |repository, task_directory|
      20.times do |index|
        directory = File.join(repository, "tree", index.to_s, "nested")
        FileUtils.mkdir_p(directory)
        File.binwrite(File.join(directory, "entry.txt"), "#{index}\n")
      end
      wrapper_directory = File.join(File.dirname(repository), "git-wrapper")
      FileUtils.mkdir_p(wrapper_directory)
      wrapper = File.join(wrapper_directory, "git")
      log = File.join(File.dirname(repository), "git-invocations.log")
      real_git = executable_on_path("git")
      File.binwrite(wrapper, <<~RUBY)
        #!#{RbConfig.ruby}
        File.open(ENV.fetch("GIT_INVOCATION_LOG"), "ab") { |file| file.write(ARGV.join(" "), "\n") }
        exec ENV.fetch("REAL_GIT"), *ARGV
      RUBY
      File.chmod(0o755, wrapper)

      stdout, stderr, status = run_tool(
        TOOLS.fetch("root-cause-repair"), task_directory,
        "PATH" => "#{wrapper_directory}:#{ENV.fetch('PATH')}",
        "REAL_GIT" => real_git,
        "GIT_INVOCATION_LOG" => log
      )
      assert status.success?, "#{stderr}\n#{stdout}"
      refute_includes File.binread(log), "check-ignore"
    end
  end

  def test_git_capture_has_a_hard_deadline
    with_repository do |repository, task_directory|
      wrapper_directory = File.join(File.dirname(repository), "slow-git-wrapper")
      FileUtils.mkdir_p(wrapper_directory)
      wrapper = File.join(wrapper_directory, "git")
      real_git = executable_on_path("git")
      File.binwrite(wrapper, <<~RUBY)
        #!#{RbConfig.ruby}
        sleep 5 if ARGV.include?("for-each-ref")
        exec ENV.fetch("REAL_GIT"), *ARGV
      RUBY
      File.chmod(0o755, wrapper)
      limited_tool = instrumented_tool(
        repository,
        "GIT_TIMEOUT_SECONDS = 60" => "GIT_TIMEOUT_SECONDS = 0.05"
      )

      assert_error_with_tool(
        limited_tool, task_directory, "git_timeout",
        "PATH" => "#{wrapper_directory}:#{ENV.fetch('PATH')}", "REAL_GIT" => real_git
      )
    end
  end

  def test_second_capture_rejects_a_change_after_the_first_walk
    with_repository do |repository, task_directory|
      marker = File.join(File.dirname(repository), "first-capture-complete")
      wait_file = File.join(File.dirname(repository), "hold-second-capture")
      File.binwrite(wait_file, "hold")
      tool = instrumented_tool(
        repository,
        "    # A writer can change a path after its first read without moving HEAD,\n" => <<~RUBY
          File.binwrite(ENV.fetch("CAPTURE_MARKER"), "ready")
          sleep 0.01 while File.exist?(ENV.fetch("CAPTURE_WAIT"))
              # A writer can change a path after its first read without moving HEAD,
        RUBY
      )

      stdout, stderr, status = run_tool_with_checkpoint(
        tool, task_directory, marker, wait_file,
        "CAPTURE_MARKER" => marker, "CAPTURE_WAIT" => wait_file
      ) do
        File.binwrite(File.join(repository, "tracked.txt"), "changed after first capture\n")
      end
      assert_tool_error(stdout, stderr, status, "state_changed")
    end
  end

  def test_file_growth_during_read_fails_before_bypassing_size_accounting
    with_repository do |repository, task_directory|
      growing = File.join(repository, "grow.bin")
      File.binwrite(growing, "a" * 1024)
      git(repository, "add", "grow.bin")
      git(repository, "commit", "-qm", "add growth fixture")
      marker = File.join(File.dirname(repository), "file-opened")
      wait_file = File.join(File.dirname(repository), "hold-file-read")
      File.binwrite(wait_file, "hold")
      tool = instrumented_tool(
        repository,
        "      bytes_read = 0\n" => <<~RUBY
          if File.basename(path) == "grow.bin"
            File.binwrite(ENV.fetch("CAPTURE_MARKER"), "ready")
            sleep 0.01 while File.exist?(ENV.fetch("CAPTURE_WAIT"))
          end
              bytes_read = 0
        RUBY
      )

      stdout, stderr, status = run_tool_with_checkpoint(
        tool, task_directory, marker, wait_file,
        "CAPTURE_MARKER" => marker, "CAPTURE_WAIT" => wait_file
      ) do
        File.open(growing, "ab") { |file| file.write("b" * 2048) }
      end
      assert_tool_error(stdout, stderr, status, "state_changed")
    end
  end

  def test_dirty_uninitialized_and_nested_dirty_submodules_fail_closed
    in_tmpdir do |directory|
      leaf = seed_git_repository(File.join(directory, "leaf"), "leaf.txt")
      middle = seed_git_repository(File.join(directory, "middle"), "middle.txt")
      add_submodule(middle, leaf, "deps/leaf")
      git(middle, "commit", "-qm", "add nested submodule")

      repository = seed_git_repository(File.join(directory, "target"), "tracked.txt")
      seed_supporting_files(repository)
      add_submodule(repository, middle, "deps/middle")
      git(repository, "commit", "-qm", "add submodule")
      task_directory = seed_hive_state(repository)

      fingerprint(task_directory)

      File.binwrite(File.join(repository, "deps", "middle", "middle.txt"), "dirty\n")
      assert_error(task_directory, "submodule_unsupported")
      git(File.join(repository, "deps", "middle"), "checkout", "--", "middle.txt")

      nested_file = File.join(repository, "deps", "middle", "deps", "leaf", "leaf.txt")
      File.binwrite(nested_file, "nested dirty\n")
      assert_error(task_directory, "submodule_unsupported")
      git(File.dirname(nested_file), "checkout", "--", "leaf.txt")

      middle_checkout = File.join(repository, "deps", "middle")
      git(middle_checkout, "submodule", "deinit", "-f", "--all")
      assert_error(task_directory, "submodule_unsupported")
      git_with_file_protocol(middle_checkout, "submodule", "update", "--init", "--recursive")

      git(repository, "submodule", "deinit", "-f", "--all")
      assert_error(task_directory, "submodule_unsupported")
    end
  end

  private

  def with_repository
    in_tmpdir do |directory|
      repository = seed_git_repository(File.join(directory, "target"), "tracked.txt")
      seed_supporting_files(repository)
      task_directory = seed_hive_state(repository)
      yield repository, task_directory
    end
  end

  def seed_git_repository(path, initial_name)
    FileUtils.mkdir_p(path)
    git(path, "init", "-q", "-b", "main")
    git(path, "config", "user.name", "Repository State Test")
    git(path, "config", "user.email", "repository-state@example.test")
    File.binwrite(File.join(path, initial_name), "initial\n")
    git(path, "add", ".")
    git(path, "commit", "-qm", "initial")
    path
  end

  def seed_supporting_files(repository)
    File.binwrite(File.join(repository, ".gitignore"), "ignored/\n")
    File.binwrite(File.join(repository, "delete-me.txt"), "delete\n")
    File.binwrite(File.join(repository, "rename-me.txt"), "rename\n")
    File.binwrite(File.join(repository, "mode-me.sh"), "#!/bin/sh\n")
    git(repository, "add", ".")
    git(repository, "commit", "-qm", "supporting files")
  end

  def seed_hive_state(repository)
    state_root = File.join(repository, ".hive-state")
    task_directory = File.join(state_root, "stages", "4-execute", "task")
    FileUtils.mkdir_p(task_directory)
    git(state_root, "init", "-q", "-b", "hive-state")
    git(state_root, "config", "user.name", "Hive State Test")
    git(state_root, "config", "user.email", "hive-state@example.test")
    File.binwrite(File.join(task_directory, "task.md"), "task\n")
    git(state_root, "add", ".")
    git(state_root, "commit", "-qm", "initial hive state")
    task_directory
  end

  def add_submodule(repository, source, path)
    git_with_file_protocol(repository, "submodule", "add", "-q", source, path)
    git_with_file_protocol(repository, "submodule", "update", "--init", "--recursive")
  end

  def fingerprint(task_directory)
    stdout, stderr, status = run_tool(TOOLS.fetch("root-cause-repair"), task_directory)
    assert status.success?, "#{stderr}\n#{stdout}"
    JSON.parse(stdout).fetch("fingerprint")
  end

  def assert_error(chdir, code)
    assert_error_with_tool(TOOLS.fetch("root-cause-repair"), chdir, code)
  end

  def assert_error_with_tool(tool, chdir, code, environment = {})
    stdout, stderr, status = run_tool(tool, chdir, environment)
    assert_tool_error(stdout, stderr, status, code)
  end

  def assert_tool_error(stdout, stderr, status, code)
    refute status.success?, stdout
    assert_empty stderr
    report = JSON.parse(stdout)
    assert_equal "error", report.fetch("status")
    assert_equal code, report.dig("error", "code")
    refute report.dig("error", "message").to_s.empty?
  end

  def run_tool(tool, chdir, environment = {})
    Open3.capture3(environment, tool, chdir: chdir)
  end

  def run_tool_with_checkpoint(tool, chdir, marker, wait_file, environment)
    stdout = stderr = status = nil
    Open3.popen3(environment, tool, chdir: chdir) do |stdin, out, err, wait_thread|
      stdin.close
      Timeout.timeout(5) { sleep 0.01 until File.exist?(marker) }
      yield
      FileUtils.rm_f(wait_file)
      stdout = out.read
      stderr = err.read
      status = wait_thread.value
    end
    [stdout, stderr, status]
  ensure
    FileUtils.rm_f(wait_file)
  end

  def instrumented_tool(repository, replacements)
    path = File.join(File.dirname(repository), "repository-state-instrumented-#{replacements.hash.abs}.rb")
    source = File.binread(TOOLS.fetch("root-cause-repair"))
    replacements.each do |needle, replacement|
      raise "instrumentation anchor missing: #{needle.inspect}" unless source.include?(needle)

      source = source.sub(needle, replacement)
    end
    File.binwrite(path, source)
    File.chmod(0o755, path)
    path
  end

  def executable_on_path(name)
    ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |directory| File.join(directory, name) }
       .find { |path| File.file?(path) && File.executable?(path) } || raise("#{name} is unavailable")
  end

  def git(repository, *arguments)
    stdout, stderr, status = Open3.capture3(
      {"GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0"},
      "git", "-c", "commit.gpgsign=false", "-C", repository, *arguments
    )
    assert status.success?, "git #{arguments.join(' ')} failed: #{stderr}\n#{stdout}"
    stdout
  end

  def git_with_file_protocol(repository, *arguments)
    git(repository, "-c", "protocol.file.allow=always", *arguments)
  end

  def filesystem_snapshot(root)
    entries = []
    walk = lambda do |directory, relative|
      Dir.each_child(directory, encoding: Encoding::BINARY).sort.each do |name|
        path = File.join(directory.b, name.b)
        child = relative.empty? ? name.b : File.join(relative.b, name.b)
        stat = File.lstat(path)
        if stat.symlink?
          entries << [child, "link", stat.mode & 0o7777, File.readlink(path).b]
        elsif stat.directory?
          entries << [child, "dir", stat.mode & 0o7777]
          walk.call(path, child)
        elsif stat.file?
          entries << [child, "file", stat.mode & 0o7777, Digest::SHA256.file(path).hexdigest]
        else
          entries << [child, "special", stat.mode]
        end
      end
    end
    walk.call(root, "".b)
    entries
  end
end
