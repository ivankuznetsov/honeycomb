# frozen_string_literal: true

require_relative "test_helper"

class RootCauseRepairDocumentationTest < Minitest::Test
  WIKI_PAGES = %w[
    index.md
    architecture.md
    command-api-surface.md
    package-catalog-contract.md
    gaps.md
  ].freeze
  LOG_FRAGMENT = "20260720T111827Z-root-cause-repair-candidate.md"

  def test_root_readme_discloses_candidate_risk_and_publication_boundary
    readme = File.read(File.join(ROOT, "README.md"))

    assert_includes readme, "packages/root-cause-repair/1.0.0"
    %w[unpublished unlisted Git-only high-risk uncommitted].each do |term|
      assert_includes readme.downcase, term.downcase, term
    end
    assert_match(/no canonical `manifest\.yml`/i, readme)
    assert_match(/arbitrary local commands/i, readme)
    assert_match(/sole authority/i, readme)
    assert_match(/no[\s\S]*public install path/i, readme)
  end

  def test_wiki_records_runtime_outcomes_evidence_limits_and_release_tail
    pages = WIKI_PAGES.to_h { |name| [name, File.read(File.join(ROOT, "wiki", name))] }
    corpus = pages.values.join("\n")

    WIKI_PAGES.each { |name| assert_includes pages.fetch(name), "Root Cause Repair", name }
    %w[verified not-reproduced blocked].each { |outcome| assert_includes corpus, outcome }
    assert_match(/install-time agent mappings|maps every executable/i, corpus)
    assert_match(/checkpoint.*concurrent|concurrent.*checkpoint/im, corpus)
    assert_match(/no canonical manifest/i, corpus)
    assert_match(/sole authority/i, corpus)
    assert_match(/explicit owner|owner-authorized/i, corpus)
    assert_match(/public-install|public install/i, corpus)
    assert_match(/template removal|template-removal/i, corpus)
  end

  def test_candidate_has_a_fragment_but_compiled_log_remains_separate
    fragment = File.join(ROOT, "wiki", "log.d", LOG_FRAGMENT)
    assert File.file?(fragment)
    assert_includes File.read(fragment), "unpublished, unlisted local source"
    assert File.file?(File.join(ROOT, "wiki", "log.md"))
  end
end
