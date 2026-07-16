# frozen_string_literal: true

require_relative "test_helper"

class OfflineContractTest < Minitest::Test
  MANIFEST = File.join(ROOT, "script", "honeycomb-manifest")
  CATALOG = File.join(ROOT, "script", "honeycomb-catalog")

  def test_runtime_has_no_network_or_non_optional_dependency_surface
    runtime = Dir[File.join(ROOT, "lib", "**", "*.rb")].sort.map { |path| File.read(path) }.join("\n")
    refute_match(/require ["'](?:net\/http|open-uri|socket|bundler)/, runtime)
    refute_match(/(?:Net::HTTP|URI\.open|TCPSocket|Socket\.tcp)/, runtime)
    refute File.exist?(File.join(ROOT, "Gemfile"))
  end

  def test_locale_and_timezone_do_not_change_manifest_or_catalog_bytes
    artifacts = []
    [
      {"LANG" => "C", "LC_ALL" => "C", "TZ" => "UTC"},
      {"LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8", "TZ" => "Pacific/Auckland"}
    ].each do |environment|
      in_tmpdir do |root|
        package = install_valid_fixture(root)
        stdout, stderr, status = capture_command_env(
          environment, MANIFEST, "--root", root, package, chdir: File.dirname(root)
        )
        assert_equal 0, status.exitstatus, [stdout, stderr].join("\n")
        stdout, stderr, status = capture_command_env(
          environment, CATALOG, "--root", root, "--evidence",
          fixture_path("listing-evidence", "passing.json"), chdir: File.dirname(root)
        )
        assert_equal 0, status.exitstatus, [stdout, stderr].join("\n")
        artifacts << [File.binread(File.join(package, "manifest.yml")),
                      File.binread(File.join(root, "catalog.json"))]
      end
    end
    assert_equal artifacts.first, artifacts.last
  end
end
