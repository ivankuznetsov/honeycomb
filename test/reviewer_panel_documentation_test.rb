# frozen_string_literal: true

require_relative "test_helper"

class ReviewerPanelDocumentationTest < Minitest::Test
  WIKI_PAGES = %w[
    index.md
    architecture.md
    command-api-surface.md
    package-catalog-contract.md
    gaps.md
  ].freeze
  LOG_FRAGMENT = "20260720T111828Z-reviewer-panel-candidate.md"

  def test_readme_separates_lenses_execution_identity_and_authority
    readme = File.read(File.join(ROOT, "README.md"))

    assert_includes readme, "packages/reviewer-panel/1.0.0"
    %w[correctness security reliability test-evidence].each { |lens| assert_includes readme, lens }
    %w[unpublished unlisted Git-only high-risk uncommitted analytical].each do |term|
      assert_includes readme.downcase, term.downcase, term
    end
    assert_match(/compatible agents or execution profiles.*do not/im, readme)
    assert_match(/does not intrinsically require.*provider/im, readme)
    assert_match(/not human\s+collaboration,\s+merge approval,\s+trust endorsement/im, readme)
    assert_match(/sole owner.*protected repository-owner publication lane/im, readme)
    assert_match(/no canonical manifest/im, readme)
  end

  def test_wiki_records_analytical_outcomes_runtime_limit_and_release_gap
    pages = WIKI_PAGES.to_h { |name| [name, File.read(File.join(ROOT, "wiki", name))] }
    corpus = pages.values.join("\n")

    WIKI_PAGES.each { |name| assert_includes pages.fetch(name), "Reviewer Panel", name }
    %w[correctness security reliability test-evidence].each { |lens| assert_includes corpus, lens }
    %w[ready changes-requested inconclusive state-stale].each { |outcome| assert_includes corpus, outcome }
    assert_match(/fixed semantic lenses|lenses are fixed semantics/i, corpus)
    assert_match(/one compatible profile|one profile/i, corpus)
    assert_match(/does not.*particular provider|not provider independence/im, corpus)
    assert_match(/checkpoint.*concurrent|concurrent.*checkpoint/im, corpus)
    assert_match(/not human collaboration|never human collaboration/i, corpus)
    assert_match(/merge approval/i, corpus)
    assert_match(/trust.*listing approval|trust\/listing approval/i, corpus)
    assert_match(/protected repository-owner/i, corpus)
    assert_match(/no canonical manifest/i, corpus)
    assert_match(/no .*public install|public install.*not/im, corpus)
    assert_match(/template removal|template-removal/i, corpus)
  end

  def test_fragment_exists_without_displacing_root_cause_or_compiled_log
    fragment = File.join(ROOT, "wiki", "log.d", LOG_FRAGMENT)
    assert File.file?(fragment)
    assert_includes File.read(fragment), "unpublished, unlisted local source"
    assert_includes File.read(File.join(ROOT, "README.md")), "packages/root-cause-repair/1.0.0"
    assert_includes File.read(File.join(ROOT, "wiki", "index.md")), "Root Cause Repair"
    assert File.file?(File.join(ROOT, "wiki", "log.md"))
  end
end
