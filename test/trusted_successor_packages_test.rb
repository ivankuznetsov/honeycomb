# frozen_string_literal: true

require_relative "test_helper"
require "psych"

class TrustedSuccessorPackagesTest < Minitest::Test
  RELEASES = {
    "architecture" => %w[1.0.2 1.0.3],
    "writing" => %w[1.0.1 1.0.2],
    "seo-content" => %w[1.0.1 1.0.2],
    "reviewer-panel" => %w[1.0.0 1.0.1],
    "video-production" => %w[0.1.0 0.1.1],
    "task-inspect" => %w[0.1.0 0.1.1],
    "docs-sync" => %w[0.1.0 0.1.1]
  }.freeze

  def test_every_successor_actor_uses_normal_trusted_execution
    RELEASES.each do |name, (_, version)|
      workflow = load_workflow(name, version)
      actors = workflow.fetch("stages").reject { |stage| stage["kind"] == "terminal" }
      actors += actors.flat_map { |stage| stage.fetch("reviewers", []) + [stage.dig("council", "revise")].compact }
      refute_empty actors, name
      actors.each do |actor|
        assert_equal "yolo", actor.fetch("permissions"), "#{name}: #{actor['name']}"
        assert_includes %w[planning development reviewer], actor.fetch("mapping_role")
        refute_empty actor.fetch("mapping_contract")
        assert_empty actor.keys & %w[agent model effort]
      end
    end
  end

  def test_successors_keep_stage_flow_and_council_completion_rules
    RELEASES.each do |name, (old, version)|
      before = load_workflow(name, old)
      after = load_workflow(name, version)
      assert_equal before["stages"].map { |stage| stage.values_at("name", "kind", "state_file", "deliverable") },
                   after["stages"].map { |stage| stage.values_at("name", "kind", "state_file", "deliverable") }, name
      before["stages"].zip(after["stages"]).each do |old_stage, new_stage|
        next unless old_stage["council"]

        assert_equal old_stage["council"].reject { |key, _| key == "revise" },
                     new_stage["council"].reject { |key, _| key == "revise" }, name
      end
    end
  end

  def test_successor_documentation_discloses_trust_without_sandbox_claims
    RELEASES.each do |name, (_, version)|
      readme = File.read(File.join(ROOT, "packages", name, version, "README.md"))
      assert_includes readme, "permissions: yolo"
      assert_includes readme, "normal tools"
      refute_match(/cannot enforce|can execute only|only read-oriented tools|no actor receives shell/, readme)
    end
  end

  private

  def load_workflow(name, version)
    Psych.safe_load_file(File.join(ROOT, "packages", name, version, "workflow.yml"))
  end
end
