# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintChangeSetTest < Minitest::Test
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
    seen = nil
    executor = lambda do |argv|
      seen = argv
      ["packages/example/1.0.0/README.md\0", "", 0]
    end
    result = HoneycombSecurityLint::ChangeSet.new(root: ROOT, executor: executor).between("a" * 40, "b" * 40)

    assert_equal "git", seen.first
    assert_equal ["packages/example/1.0.0"], result.version_roots
    assert_raises(HoneycombSecurityLint::ChangeSet::Invalid) do
      HoneycombSecurityLint::ChangeSet.new(root: ROOT, executor: executor).between("$(bad)", "b" * 40)
    end
  end
end
