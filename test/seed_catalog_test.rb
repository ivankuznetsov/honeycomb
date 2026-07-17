# frozen_string_literal: true

require_relative "test_helper"
require "digest"

class SeedCatalogTest < Minitest::Test
  BENCH = File.join(ROOT, "packages", "bench", "0.1.0")
  DOCS_SYNC = File.join(ROOT, "packages", "docs-sync", "0.1.0")
  DOCS_SYNC_SOURCE_REVISION = "057af38a6f5f3cdd03d18a3283f5b541668285bc"
  UPSTREAM_BENCH_INSTRUCTION_DIGESTS = {
    "extract.md" => "f143fd4c4e7ce4e6679a903a800e35f8c0556b260d81a034930adb0d45fb45fa",
    "generate.md" => "bd5923118ec824beee8ff96fb6e29e9a49f00665d6b40b93e5538211072edaa6",
    "judge.md" => "d2441d36d776dbe970e88816410b9c9c4c0d22598d3ff4a6f955a8927cf89ccd",
    "publish.md" => "81ae24aa477a2041ecc84a6d47b7a1ab177d5ea9759293cd50333e6193bbd786"
  }.freeze

  def manifest(path)
    HoneycombRegistry::SafeYAML.load_file(File.join(path, "manifest.yml"))
  end

  def workflow(path)
    HoneycombRegistry::SafeYAML.load_file(File.join(path, "workflow.yml"))
  end

  def test_bench_is_the_pinned_upstream_snapshot_with_only_descriptor_path_translation
    document = manifest(BENCH)
    descriptor = workflow(BENCH)

    assert_equal "b4f462848d439d07e97e1e37943d738e8ca8d28a", document.dig("source", "revision")
    assert_equal %w[inbox extract generate judge publish done], descriptor.fetch("stages").map { |stage| stage.fetch("name") }
    assert_equal(
      %w[instructions/extract.md instructions/generate.md instructions/judge.md instructions/publish.md],
      descriptor.fetch("stages").filter_map { |stage| stage["instruction"] }
    )
    UPSTREAM_BENCH_INSTRUCTION_DIGESTS.each do |basename, expected|
      actual = Digest::SHA256.file(File.join(BENCH, "instructions", basename)).hexdigest
      assert_equal expected, actual, basename
    end
    assert_equal "high", document.dig("permissions", "risk")
    assert_equal ["*"], document.dig("permissions", "network_hosts")
    assert_equal ["*"], document.dig("permissions", "filesystem_write")
    assert_equal ["*"], document.dig("permissions", "secrets")
  end

  def test_docs_sync_is_a_bounded_two_stage_honeycomb_with_content_provenance
    document = manifest(DOCS_SYNC)
    descriptor = workflow(DOCS_SYNC)
    stages = descriptor.fetch("stages")

    assert_equal %w[inspect update-docs], stages.map { |stage| stage.fetch("name") }
    assert_equal %w[instructions/inspect.md instructions/update-docs.md], stages.map { |stage| stage.fetch("instruction") }
    stages.each do |stage|
      tools = stage.dig("permissions", "tools")
      assert_empty(tools & %w[Bash WebFetch WebSearch])
      assert_empty(tools & %w[Write MultiEdit NotebookEdit])
      assert_equal ["../../../.."], stage.dig("permissions", "dirs")
    end
    assert_equal "Edit(./inspect.md)", stages.first.dig("permissions", "tools").last
    assert_equal(
      ["Edit(./update-docs.md)", "Edit(../../../../docs/**)"],
      stages.last.dig("permissions", "tools").last(2)
    )
    assert_equal "0.4.3", document.fetch("hive_min_version")
    assert_equal "moderate", document.dig("permissions", "risk")
    assert_equal [], document.dig("permissions", "network_hosts")
    assert_equal %w[repository task], document.dig("permissions", "filesystem_read")
    assert_equal(
      %w[repository/docs/** task/inspect.md task/update-docs.md],
      document.dig("permissions", "filesystem_write")
    )
    assert_equal [], document.dig("permissions", "secrets")

    paths = document.dig("x-provenance", "source_paths").sort
    assert_equal DOCS_SYNC_SOURCE_REVISION, document.dig("source", "revision")
    assert_includes document.dig("source", "url"), DOCS_SYNC_SOURCE_REVISION
    paths.each do |path|
      source, stderr, status = Open3.capture3(
        "git", "show", "#{DOCS_SYNC_SOURCE_REVISION}:packages/docs-sync/0.1.0/#{path}", chdir: ROOT
      )
      assert status.success?, stderr
      assert_equal File.binread(File.join(DOCS_SYNC, path)), source.b, path
    end
  end

  def test_seed_readmes_publish_exact_install_commands_and_no_embedded_reviews
    bench_readme = File.read(File.join(BENCH, "README.md"))
    docs_readme = File.read(File.join(DOCS_SYNC, "README.md"))

    assert_includes bench_readme, "hive workflow install honeycomb/bench"
    assert_includes docs_readme, "hive workflow install honeycomb/docs-sync"
    refute Dir.exist?(File.join(BENCH, "reviews"))
    refute Dir.exist?(File.join(DOCS_SYNC, "reviews"))
  end

  def test_tampering_with_each_seed_breaks_integrity_validation
    [BENCH, DOCS_SYNC].each do |source|
      in_tmpdir do |root|
        destination = File.join(root, "packages", File.basename(File.dirname(source)), File.basename(source))
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp_r(source, destination)
        File.open(File.join(destination, "README.md"), "a") { |file| file << "tampered\n" }

        package = HoneycombRegistry::Package.new(destination, root: root)
        findings = HoneycombRegistry::Validator.validate(package)
        assert findings.errors?, source
        assert_includes findings.codes, "integrity.digest_mismatch"
      end
    end
  end
end
