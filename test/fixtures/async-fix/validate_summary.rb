#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/fixture_support"

module AsyncFixSummaryValidator
  SCHEMA = "honeycomb-async-fix-docker-smoke/v1"
  RUBY_VERSION = "3.4.5"
  EXPECTED_METRICS = {
    "registry_clones" => 3,
    "target_fetches" => 3,
    "target_pushes" => 2,
    "pr_creates" => 2,
    "repair_agent_spawns" => 2,
    "deny_probes" => 7
  }.freeze
  SUMMARY_KEYS = %w[schema ok honeycomb_revision hive_revision ruby proofs metrics tasks].sort.freeze

  module_function

  def validate!(output, honeycomb_revision:, hive_revision:)
    lines = output.lines.map(&:strip).reject(&:empty?)
    raise "container must emit exactly one non-empty summary line" unless lines.length == 1

    document = JSON.parse(lines.first)
    assert_equal(SUMMARY_KEYS, document.keys.sort, "summary keys")
    assert_equal(SCHEMA, document.fetch("schema"), "summary schema")
    assert_equal(true, document.fetch("ok"), "summary ok")
    assert_equal(honeycomb_revision, document.fetch("honeycomb_revision"), "Honeycomb revision")
    assert_equal(hive_revision, document.fetch("hive_revision"), "Hive revision")
    assert_equal(RUBY_VERSION, document.fetch("ruby"), "Ruby version")
    assert_equal(
      AsyncFixFixtureSupport::REQUIRED_PROOFS.to_h { |proof| [proof, true] },
      document.fetch("proofs"),
      "required proofs"
    )
    assert_equal(EXPECTED_METRICS, document.fetch("metrics"), "mutation metrics")

    tasks = document.fetch("tasks")
    unless tasks.is_a?(Array) && tasks.length == 2 && tasks.uniq.length == 2 &&
           tasks.all? { |slug| slug.is_a?(String) && slug.match?(/\A[a-z0-9][a-z0-9-]+\z/) }
      raise "tasks must contain two distinct task slugs"
    end

    document
  rescue JSON::ParserError => e
    raise "container summary is invalid JSON: #{e.message}"
  end

  def assert_equal(expected, actual, label)
    return if expected == actual

    raise "#{label}: expected #{expected.inspect}, got #{actual.inspect}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    AsyncFixSummaryValidator.validate!(
      $stdin.read,
      honeycomb_revision: ARGV.fetch(0),
      hive_revision: ARGV.fetch(1)
    )
  rescue StandardError => e
    warn "async-fix smoke: #{e.message}"
    exit 1
  end
end
