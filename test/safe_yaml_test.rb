# frozen_string_literal: true

require_relative "test_helper"

class SafeYamlTest < Minitest::Test
  def test_loads_only_json_like_values
    value = HoneycombRegistry::SafeYAML.load(<<~YAML, path: "input.yml")
      name: example
      enabled: true
      count: 2
      values:
        - null
        - "text"
    YAML

    assert_equal({"name" => "example", "enabled" => true, "count" => 2,
                  "values" => [nil, "text"]}, value)
  end

  def test_rejects_duplicate_keys
    error = assert_raises(HoneycombRegistry::SafeYAML::Invalid) do
      HoneycombRegistry::SafeYAML.load("name: one\nname: two\n", path: "input.yml")
    end

    assert_equal "yaml.duplicate_key", error.code
    assert_equal "input.yml.name", error.path
  end

  def test_rejects_aliases_custom_tags_and_non_string_keys
    cases = {
      "one: &value x\ntwo: *value\n" => "yaml.alias",
      "value: !ruby/object:Object {}\n" => "yaml.tag",
      "1: numeric\n" => "yaml.non_string_key"
    }

    cases.each do |yaml, code|
      error = assert_raises(HoneycombRegistry::SafeYAML::Invalid) do
        HoneycombRegistry::SafeYAML.load(yaml, path: "input.yml")
      end
      assert_equal code, error.code
    end
  end

  def test_rejects_invalid_utf8_and_non_finite_numbers
    error = assert_raises(HoneycombRegistry::SafeYAML::Invalid) do
      HoneycombRegistry::SafeYAML.load("name: \xFF".b, path: "input.yml")
    end
    assert_equal "yaml.invalid_encoding", error.code

    error = assert_raises(HoneycombRegistry::SafeYAML::Invalid) do
      HoneycombRegistry::SafeYAML.load("value: .nan\n", path: "input.yml")
    end
    assert_equal "yaml.non_json_value", error.code
  end
end
