# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
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

  def install_valid_fixture(root)
    package = File.join(root, "packages", "example", "1.0.0")
    FileUtils.mkdir_p(File.dirname(package))
    FileUtils.cp_r(fixture_path("packages", "valid", "example", "1.0.0"), package)
    package
  end

  def capture_command(*arguments, chdir: ROOT)
    Open3.capture3(RbConfig.ruby, *arguments, chdir: chdir)
  end
end

class Minitest::Test
  include TestSupport
end
