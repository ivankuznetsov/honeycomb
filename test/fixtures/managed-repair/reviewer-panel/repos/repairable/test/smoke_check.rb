require "minitest/autorun"
require_relative "../lib/value"

class SmokeTest < Minitest::Test
  def test_answer_is_an_integer
    assert_kind_of Integer, PanelValue.answer
  end
end
