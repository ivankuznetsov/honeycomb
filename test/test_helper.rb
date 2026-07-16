# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

require "honeycomb_registry"

module TestSupport
  def fixture_path(*parts)
    File.join(ROOT, "test", "fixtures", *parts)
  end

  def in_tmpdir
    Dir.mktmpdir("honeycomb-registry-test") { |dir| yield dir }
  end
end

class Minitest::Test
  include TestSupport
end
