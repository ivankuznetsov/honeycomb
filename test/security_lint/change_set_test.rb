# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintChangeSetTest < Minitest::Test
  def git(root, *arguments)
    stdout, stderr, status = Open3.capture3("git", *arguments, chdir: root)
    raise [stdout, stderr].join("\n") unless status.success?
    stdout.strip
  end

  def test_parses_nul_delimited_changed_versions_deterministically
    change_set = HoneycombSecurityLint::ChangeSet.new(root: ROOT)
    result = change_set.parse(
      "packages/example/1.0.0/README.md\0packages/alpha-test/2.0.0/instructions/a.md\0"
    )

    assert_equal ["packages/alpha-test/2.0.0", "packages/example/1.0.0"], result.version_roots
    assert_equal 2, result.paths.length
  end

  def test_rejects_nonterminated_traversing_backslash_and_unusual_paths
    change_set = HoneycombSecurityLint::ChangeSet.new(root: ROOT)
    invalid = [
      "packages/example/1.0.0/README.md",
      "packages/example/1.0.0/../README.md\0",
      "packages\\example\\1.0.0\\README.md\0",
      "packages/example/1.0.0/odd\nname.md\0",
      "/packages/example/1.0.0/README.md\0"
    ]
    invalid.each do |paths|
      assert_raises(HoneycombSecurityLint::ChangeSet::Invalid) { change_set.parse(paths) }
    end
  end

  def test_invokes_git_without_a_shell_and_validates_shas
    seen = []
    executor = lambda do |argv|
      seen << argv
      if argv[1] == "diff"
        ["packages/example/1.0.0/README.md\0", "", 0]
      else
        ["packages/example/1.0.0\0", "", 0]
      end
    end
    result = HoneycombSecurityLint::ChangeSet.new(root: ROOT, executor: executor).between("a" * 40, "b" * 40)

    assert seen.all? { |argv| argv.first == "git" }
    assert_equal ["packages/example/1.0.0"], result.version_roots
    assert_equal ["packages/example/1.0.0"], result.existing_version_roots
    assert_equal %w[git ls-tree -d --name-only -z], seen.last.first(5)
    assert_raises(HoneycombSecurityLint::ChangeSet::Invalid) do
      HoneycombSecurityLint::ChangeSet.new(root: ROOT, executor: executor).between("$(bad)", "b" * 40)
    end
  end

  def test_distinguishes_new_versions_from_existing_version_mutations
    executor = lambda do |argv|
      if argv[1] == "diff"
        [
          "packages/example/1.0.0/README.md\0packages/example/1.1.0/README.md\0",
          "", 0
        ]
      else
        ["packages/example/1.0.0\0", "", 0]
      end
    end

    result = HoneycombSecurityLint::ChangeSet.new(root: ROOT, executor: executor)
                                                   .between("a" * 40, "b" * 40)

    assert_equal ["packages/example/1.0.0", "packages/example/1.1.0"], result.version_roots
    assert_equal ["packages/example/1.0.0"], result.existing_version_roots
  end

  def test_exact_directory_rename_still_reports_the_removed_immutable_version
    in_tmpdir do |root|
      path = File.join(root, "packages", "example", "1.0.0")
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "README.md"), "same bytes\n")
      git(root, "init", "-q")
      git(root, "config", "user.name", "Change Set Test")
      git(root, "config", "user.email", "change-set@example.test")
      git(root, "add", ".")
      git(root, "-c", "commit.gpgsign=false", "commit", "-qm", "base")
      base = git(root, "rev-parse", "HEAD")
      git(root, "mv", "packages/example/1.0.0", "packages/example/1.1.0")
      git(root, "-c", "commit.gpgsign=false", "commit", "-am", "rename version", "-q")
      head = git(root, "rev-parse", "HEAD")

      result = HoneycombSecurityLint::ChangeSet.new(root: root).between(base, head)

      assert_equal ["packages/example/1.0.0", "packages/example/1.1.0"], result.version_roots
      assert_equal ["packages/example/1.0.0"], result.existing_version_roots
    end
  end
end
