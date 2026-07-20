require "minitest/autorun"
require_relative "../lib/loader"

class LoaderTest < Minitest::Test
  def test_literal_expression
    assert_equal 2, UnsafeLoader.load("1 + 1")
  end
end
