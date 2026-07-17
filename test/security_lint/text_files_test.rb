# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintTextFilesTest < Minitest::Test
  def limits(overrides = {})
    {"max_file_bytes" => 1024, "max_total_bytes" => 4096, "max_files" => 20}.merge(overrides)
  end

  def test_collects_nested_dotfiles_manifest_and_binary_accounting
    in_tmpdir do |root|
      version = File.join(root, "packages", "example", "1.0.0")
      FileUtils.mkdir_p(File.join(version, "instructions"))
      File.write(File.join(version, "manifest.yml"), "schema: example\n")
      File.write(File.join(version, ".env.example"), "TOKEN=placeholder\n")
      File.write(File.join(version, "instructions", "nested.md"), "hello\n")
      File.binwrite(File.join(version, "asset.bin"), "a\0b")

      result = HoneycombSecurityLint::TextFiles.new(root: root, limits: limits).collect("packages/example/1.0.0")

      assert_equal 4, result.files.length
      assert_equal ["binary", "text", "text", "text"], result.files.map { |file| file.evidence["kind"] }.sort
      assert result.files.all? { |file| file.evidence.keys.sort == %w[bytes kind path sha256] }
    end
  end

  def test_fails_closed_for_symlinks_invalid_encoding_and_resource_limits
    in_tmpdir do |root|
      version = File.join(root, "packages", "example", "1.0.0")
      FileUtils.mkdir_p(version)
      File.symlink("missing", File.join(version, "link"))
      scanner = HoneycombSecurityLint::TextFiles.new(root: root, limits: limits)
      assert_raises(HoneycombSecurityLint::TextFiles::Invalid) { scanner.collect("packages/example/1.0.0") }
    end

    in_tmpdir do |root|
      version = File.join(root, "packages", "example", "1.0.0")
      FileUtils.mkdir_p(version)
      File.binwrite(File.join(version, "bad.txt"), "\xff")
      scanner = HoneycombSecurityLint::TextFiles.new(root: root, limits: limits)
      assert_raises(HoneycombSecurityLint::TextFiles::Invalid) { scanner.collect("packages/example/1.0.0") }
    end

    in_tmpdir do |root|
      version = File.join(root, "packages", "example", "1.0.0")
      FileUtils.mkdir_p(version)
      File.write(File.join(version, "large.txt"), "a" * 20)
      scanner = HoneycombSecurityLint::TextFiles.new(root: root, limits: limits("max_file_bytes" => 10))
      assert_raises(HoneycombSecurityLint::TextFiles::Invalid) { scanner.collect("packages/example/1.0.0") }
    end
  end
end
