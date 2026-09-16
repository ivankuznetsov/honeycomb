# frozen_string_literal: true

require_relative "test_helper"
require "hive"
require "hive/workflows/descriptor_parser"
require "hive/task_action"

class ArchitectureDoneTest < Minitest::Test
  def setup
    @workflow = Hive::Workflows::DescriptorParser.parse_package_file(
      File.join(ROOT, "packages/architecture/1.0.4/workflow.yml"), package_name: "architecture"
    )
  end

  def test_completion_advances_to_done_and_preserves_the_document
    writer = @workflow.stage_named("architecture")
    done = @workflow.next_stage_after("architecture")
    assert_equal "7-architecture", writer.dir
    assert_equal "8-done", done.dir
    assert_equal :inert, done.kind
    assert_nil @workflow.next_stage_after("done")
    if @workflow.respond_to?(:result) # Typed results postdate the minimum supported Hive.
      assert_equal :document, @workflow.result.kind
      assert_equal "architecture.md", @workflow.result.primary_artifact
    end
    assert_equal writer.state_file, done.state_file
  end

  def test_existing_stages_and_permissions_are_preserved
    before = YAML.safe_load_file(File.join(ROOT, "packages/architecture/1.0.3/workflow.yml"))
    after = YAML.safe_load_file(File.join(ROOT, "packages/architecture/1.0.4/workflow.yml"))
    before.fetch("stages").last.delete("deliverable")
    assert_equal before.fetch("stages"), after.fetch("stages")[0...-1]
  end

  def test_completed_writer_is_ready_to_advance_and_done_is_archived
    action = Hive::TaskAction.allocate
    workflow = @workflow
    action.define_singleton_method(:task_workflow) { workflow }
    action.define_singleton_method(:marker) { Struct.new(:name).new(:complete) }
    assert_equal Hive::TaskAction::ACTIONS.fetch(:ready_to_advance),
                 action.send(:generic_action, @workflow.stage_named("architecture"))
    assert_equal Hive::TaskAction::ACTIONS.fetch(:done),
                 action.send(:generic_action, @workflow.stage_named("done"))
  end
end
