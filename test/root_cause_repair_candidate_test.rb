# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

class RootCauseRepairCandidateTest < Minitest::Test
  ROOT_CAUSE_CANDIDATE = File.join(ROOT, "candidates", "root-cause-repair")
  MUTATING_STAGES = %w[reproduce diagnose repair revise-repair verify].freeze

  def test_candidate_is_complete_manifest_free_and_outside_package_catalog
    expected = %w[
      README.md
      assets/evidence-contract.md
      instructions/certificate.md
      instructions/diagnose.md
      instructions/repair.md
      instructions/reproduce.md
      instructions/revise-repair.md
      instructions/verify.md
      tools/repository-state.rb
      workflow.yml
    ]
    actual = Dir.glob(File.join(ROOT_CAUSE_CANDIDATE, "**", "*"))
                .select { |path| File.file?(path) }
                .map { |path| path.delete_prefix("#{ROOT_CAUSE_CANDIDATE}/") }
                .sort
    assert_equal expected, actual
    refute File.exist?(File.join(ROOT_CAUSE_CANDIDATE, "manifest.yml"))
    assert File.executable?(File.join(ROOT_CAUSE_CANDIDATE, "tools", "repository-state.rb"))
  end

  def test_every_active_stage_uses_bound_checkpoint_comparison
    instructions = MUTATING_STAGES.to_h do |name|
      [name, File.read(File.join(ROOT_CAUSE_CANDIDATE, "instructions", "#{name}.md"))]
    end

    assert_match(/repository-state\.rb`?\s+`?create/i, instructions.fetch("reproduce"))
    instructions.each do |name, source|
      next if name == "reproduce"

      assert_match(/repository-state\.rb`?\s+`?compare\s+--expect/i, source, name)
    end
    instructions.each do |name, source|
      assert_match(/repository-state\.rb`?\s+`?inventory\s+--expect/i, source, name)
      assert_match(/repository-state\.rb`?\s+`?advance\s+--allow-worktree\s+<worktree-change-digest>\s+--expect/i, source, name)
      assert_match(/checkpoint digest/i, source, name)
      assert_match(/verdict.*blocked|blocked.*verdict/i, source, name)
      assert_match(/unrelated.*ref/i, source, name)
    end

    certificate = File.read(File.join(ROOT_CAUSE_CANDIDATE, "instructions", "certificate.md"))
    assert_operator certificate.scan(/repository-state\.rb`?\s+`?compare\s+--expect/i).length, :>=, 2
    refute_match(/repository-state\.rb`?\s+`?advance/i, certificate)
  end

  def test_candidate_contract_pins_verdicts_bounds_and_terminal_outcomes
    contract = File.read(File.join(ROOT_CAUSE_CANDIDATE, "assets", "evidence-contract.md"))
    %w[
      unchanged unrelated_refs worktree_changes target_changed ambiguous_refs
      state_changed checkpoint_recovered
    ].each do |reason|
      assert_includes contract, reason
    end
    assert_match(/50\s+changed-ref records/i, contract)
    assert_match(/creations?.*deletions?|deletions?.*creations?/im, contract)
    assert_match(/non-current local branch/i, contract)
    assert_match(/tags?.*stash.*ambiguous/i, contract)
    assert_match(/phase-scoped|stage checkpoint/i, contract)

    certificate = File.read(File.join(ROOT_CAUSE_CANDIDATE, "instructions", "certificate.md"))
    assert_match(/Outcome: verified\|not-reproduced\|blocked/, certificate)
    assert_match(/state_changed.*blocked|blocked.*state_changed/i, certificate)
  end

  def test_workflow_keeps_original_stage_topology_and_permissions
    workflow = YAML.safe_load(File.read(File.join(ROOT_CAUSE_CANDIDATE, "workflow.yml")))
    stages = workflow.fetch("stages")
    assert_equal %w[inbox reproduce diagnose repair verification certificate],
                 stages.map { |stage| stage.fetch("name") }
    executable = stages.reject { |stage| stage.fetch("kind") == "terminal" }
    assert executable.all? { |stage| stage.fetch("permissions") == "yolo" }
    assert_equal "repair-certificate.md", stages.last.fetch("deliverable")
    assert_equal(
      {
        "complete" => %w[verified not-reproduced],
        "blocked" => [ "blocked" ]
      },
      stages.last.fetch("terminal_outcomes")
    )
  end

  def test_candidate_readme_states_unpublished_boundary
    readme = File.read(File.join(ROOT_CAUSE_CANDIDATE, "README.md"))
    assert_match(/unpublished candidate/i, readme)
    assert_match(/no manifest/i, readme)
    assert_match(/do(?:es)? not\s+authorize.*release|release.*not authorized/im, readme)
    refute_match(/immutable `1\.0\.0` package source/i, readme)
  end
end
