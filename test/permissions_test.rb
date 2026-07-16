# frozen_string_literal: true

require_relative "test_helper"

class PermissionsTest < Minitest::Test
  def descriptor_with(stage)
    {"id" => "example", "stages" => [stage]}
  end

  def active_stage(permissions: :missing)
    stage = {
      "name" => "build",
      "kind" => "agent",
      "state_file" => "work.md",
      "instruction" => "instructions/build.md"
    }
    stage["permissions"] = permissions unless permissions == :missing
    stage
  end

  def test_read_only_is_bounded_and_low_risk
    result = HoneycombRegistry::Permissions.derive(
      descriptor_with(active_stage(permissions: "read-only")), path: "workflow.yml"
    )

    refute result.findings.errors?
    assert_equal(
      {
        "risk" => "low",
        "capabilities" => ["filesystem-read"],
        "network_hosts" => [],
        "filesystem_read" => %w[repository task],
        "filesystem_write" => [],
        "secrets" => []
      },
      result.permissions
    )
    assert_includes result.findings.codes, "permissions.source"
  end

  def test_unions_stage_reviewer_and_revise_permissions_with_attribution
    council = active_stage(permissions: "read-only").merge(
      "kind" => "council",
      "reviewers" => [
        {
          "name" => "writer",
          "prompt" => "Review it",
          "permissions" => {
            "preset" => "scoped",
            "tools" => %w[Read Write],
            "dirs" => ["artifacts", "./cache"]
          }
        }
      ],
      "council" => {
        "revise" => {
          "prompt" => "Revise it",
          "permissions" => {"preset" => "scoped", "tools" => ["WebFetch"]}
        }
      }
    )

    result = HoneycombRegistry::Permissions.derive(descriptor_with(council), path: "workflow.yml")

    refute result.findings.errors?, result.findings.to_h.inspect
    assert_equal "high", result.permissions["risk"]
    assert_equal %w[filesystem-read filesystem-write network], result.permissions["capabilities"]
    assert_equal ["*"], result.permissions["network_hosts"]
    assert_equal %w[repository task task/artifacts task/cache], result.permissions["filesystem_read"]
    assert_equal %w[repository task task/artifacts task/cache], result.permissions["filesystem_write"]
    assert result.findings.to_h.any? { |finding| finding["path"].include?("reviewers[0]") }
    assert result.findings.to_h.any? { |finding| finding["path"].include?("revise") }
  end

  def test_absent_yolo_and_bash_are_explicitly_unbounded
    specs = [
      :missing,
      "yolo",
      {"preset" => "scoped", "bash" => true}
    ]

    specs.each do |spec|
      result = HoneycombRegistry::Permissions.derive(
        descriptor_with(active_stage(permissions: spec)), path: "workflow.yml"
      )
      assert_equal "high", result.permissions["risk"]
      assert_equal HoneycombRegistry::Schema::CAPABILITIES, result.permissions["capabilities"]
      %w[network_hosts filesystem_read filesystem_write secrets].each do |key|
        assert_equal ["*"], result.permissions[key]
      end
      assert_includes result.findings.codes, "permissions.unbounded"
    end
  end

  def test_rejects_unsafe_dirs
    ["/tmp", "../outside", "safe\\ambiguous", "bad\0dir"].each do |dir|
      result = HoneycombRegistry::Permissions.derive(
        descriptor_with(active_stage(permissions: {
          "preset" => "scoped", "tools" => ["Read"], "dirs" => [dir]
        })),
        path: "workflow.yml"
      )
      assert result.findings.errors?, dir.inspect
      assert_includes result.findings.codes, "permissions.invalid_dir"
    end
  end

  def test_fails_closed_for_unknown_permission_shapes_and_tools
    specs = [
      "reckless",
      {"preset" => "scoped", "tools" => ["UnknownTool"]},
      {"preset" => "scoped", "tools" => ["Read"], "future" => true},
      {"preset" => "scoped"},
      nil
    ]

    specs.each do |spec|
      result = HoneycombRegistry::Permissions.derive(
        descriptor_with(active_stage(permissions: spec)), path: "workflow.yml"
      )
      assert result.findings.errors?, spec.inspect
      assert_nil result.permissions
    end
  end

  def test_rejects_permission_bearing_future_constructs
    descriptor = descriptor_with(active_stage(permissions: "read-only"))
    descriptor["stages"][0]["permission_overrides"] = {"network" => true}

    result = HoneycombRegistry::Permissions.derive(descriptor, path: "workflow.yml")

    assert result.findings.errors?
    assert_includes result.findings.codes, "permissions.unknown_construct"
  end
end
