require "minitest/autorun"
require_relative "../lib/value"

class ValueTest < Minitest::Test
  def test_answer
    assert_equal 42, PanelValue.answer
  end
end
