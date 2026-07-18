# frozen_string_literal: true

require_relative "test_helper"

class CanonicalJSONTest < Minitest::Test
  def test_empty_containers_are_compact_across_json_versions
    ruby_32_output = <<~JSON.chomp
      {
        "entries": [

        ],
        "metadata": {

        }
      }
    JSON
    expected = <<~JSON
      {
        "entries": [],
        "metadata": {}
      }
    JSON

    assert_equal expected.chomp,
                 HoneycombRegistry::CanonicalJSON.normalize_empty_containers(ruby_32_output)
    assert_equal expected,
                 HoneycombRegistry::CanonicalJSON.dump({"entries" => [], "metadata" => {}})
  end
end
