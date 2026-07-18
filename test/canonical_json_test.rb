# frozen_string_literal: true

require_relative "test_helper"

class CanonicalJSONTest < Minitest::Test
  def test_matches_the_hive_catalog_consumer_contract
    document = {
      "schema" => "honeycomb-catalog/v2",
      "metadata" => {},
      "entries" => [{"z" => [], "ratio" => 1.25, "a" => "Cafe\u0301"}]
    }
    expected = "{\"entries\":[{\"a\":\"Café\",\"ratio\":1.25,\"z\":[]}]," \
               "\"metadata\":{},\"schema\":\"honeycomb-catalog/v2\"}\n"

    assert_equal expected, HoneycombRegistry::CanonicalJSON.dump(document)
    assert_equal expected, HoneycombRegistry::CanonicalJSON.dump(JSON.parse(expected))
  end

  def test_rejects_values_without_a_hive_canonical_encoding
    assert_raises(ArgumentError) do
      HoneycombRegistry::CanonicalJSON.dump({"ratio" => Float::INFINITY})
    end
    assert_raises(ArgumentError) do
      HoneycombRegistry::CanonicalJSON.dump({"value" => Object.new})
    end
  end

  def test_checked_in_catalog_is_canonical
    bytes = File.binread(File.join(ROOT, "catalog.json"))

    assert_equal bytes, HoneycombRegistry::CanonicalJSON.dump(JSON.parse(bytes))
  end
end
