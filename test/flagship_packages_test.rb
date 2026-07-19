# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "honeycomb_security_lint"
require "psych"

class FlagshipPackagesTest < Minitest::Test
  FLAGSHIPS = %w[architecture writing seo-content].freeze
  IDENTITY_KEYS = %w[agent model effort].freeze
  AGENT_PLUGINS_REVISION = "e2caed2878ff1996f235ad0122bf7fea2eea3a27"

  def test_every_flagship_has_agent_agnostic_mapped_executable_slots
    FLAGSHIPS.each do |name|
      workflow = load_workflow(name)
      slots = executable_slots(workflow)

      assert_empty recursive_keys(workflow) & IDENTITY_KEYS, "#{name} embeds execution identity"
      refute_empty slots, name
      slots.each do |slot_id, actor|
        assert_empty actor.keys & IDENTITY_KEYS, "#{slot_id} embeds execution identity"
        assert_includes %w[planning development reviewer], actor.fetch("mapping_role"), slot_id
        assert_match(HoneycombRegistry::HiveCompatibility::MAPPING_CONTRACT_PATTERN,
                     actor.fetch("mapping_contract"), slot_id)
        assert actor.key?("permissions"), "#{slot_id} has no exact permissions"
      end
    end
  end

  def test_architecture_has_research_council_revision_and_terminal_deliverable
    workflow = load_workflow("architecture")

    assert_equal %w[inbox research draft review architecture], stage_names(workflow)
    review = stage(workflow, "review")
    assert_equal 2, review.dig("council", "quorum")
    assert_equal 3, review.dig("council", "max_rounds")
    assert_equal 2, review.fetch("reviewers").size
    assert review.dig("council", "revise")
    assert_equal "architecture.md", stage(workflow, "architecture").fetch("deliverable")

    final_instruction = instruction("architecture", "architecture.md")
    %w[evidence constraints tradeoffs components data-flow reviewer].each do |term|
      assert_includes final_instruction.downcase, term
    end
  end

  def test_writing_has_grounded_journalism_and_a_five_round_editorial_cap
    workflow = load_workflow("writing")

    assert_equal %w[inbox repo-research web-research research draft editorial deliver], stage_names(workflow)
    editorial = stage(workflow, "editorial")
    assert_equal 5, editorial.dig("council", "max_rounds")
    assert_equal "complete", editorial.dig("council", "on_max_rounds")
    assert_equal 2, editorial.fetch("reviewers").size
    assert_equal "article.md", stage(workflow, "deliver").fetch("deliverable")

    corpus = package_markdown("writing").downcase
    assert_includes corpus, "ungrounded"
    assert_includes corpus, "five-round-cap"
    assert_includes corpus, "source-to-claim"
    assert_includes corpus, "start over"
  end

  def test_seo_content_has_the_complete_flow_and_a_publishable_deliverable
    workflow = load_workflow("seo-content")

    assert_equal %w[inbox repo-research web-research provider-data research intent outline draft fact-check humanize analyze optimize],
                 stage_names(workflow)
    assert_equal "article.md", stage(workflow, "optimize").fetch("deliverable")
    repo_permissions = stage(workflow, "repo-research").fetch("permissions")
    web_permissions = stage(workflow, "web-research").fetch("permissions")
    provider_permissions = stage(workflow, "provider-data").fetch("permissions")
    assert_includes repo_permissions.fetch("dirs"), "../../../.."
    refute_includes repo_permissions.fetch("tools"), "WebSearch"
    assert_includes web_permissions.fetch("tools"), "WebSearch"
    refute web_permissions.key?("dirs")
    assert provider_permissions.fetch("tools").any? { |tool| tool.start_with?("Bash(") }
    refute_equal "yolo", stage(workflow, "optimize").fetch("permissions")

    corpus = package_markdown("seo-content").downcase
    %w[ga4 gsc dataforseo ahrefs prompt-only partial data claim-level humanization measurable].each do |term|
      assert_includes corpus, term
    end
  end

  def test_seo_analyzer_is_executable_deterministic_and_secret_blind
    tool = package_path("seo-content", "tools", "seo-analyze.rb")
    assert File.executable?(tool), "#{tool} must retain executable mode"

    in_tmpdir do |directory|
      article = File.join(directory, "article.md")
      File.write(article, "# Useful title\n\nA short factual paragraph.\n\n## Next step\n")
      stdout, stderr, status = Open3.capture3(tool, article)

      assert status.success?, stderr
      report = JSON.parse(stdout)
      assert_equal "seo-analyzer/v1", report.fetch("schema")
      assert_equal 1, report.dig("headings", "h1")
      assert_equal 1, report.dig("headings", "h2")
      refute_match(/token|password|secret/i, stdout)
    end
  end

  def test_seo_analyzer_counts_keyword_tokens_not_substrings
    tool = package_path("seo-content", "tools", "seo-analyze.rb")
    in_tmpdir do |directory|
      article = File.join(directory, "article.md")
      File.write(article, "# Art direction for articles\n\nThe article discusses art.\n\n## Result\n")
      stdout, stderr, status = Open3.capture3(tool, "--keyword", "art", article)

      assert status.success?, stderr
      assert_equal 2, JSON.parse(stdout).dig("primary_keyword", "occurrences")
    end
  end

  def test_provider_adapter_is_bounded_and_prompt_only_without_credentials
    tool = package_path("seo-content", "tools", "provider-metrics.rb")
    stdout, stderr, status = Open3.capture3(
      {"AHREFS_API_KEY" => nil, "DATAFORSEO_LOGIN" => nil, "DATAFORSEO_PASSWORD" => nil,
       "GA4_ACCESS_TOKEN" => nil, "GA4_PROPERTY_ID" => nil, "GSC_ACCESS_TOKEN" => nil},
      tool, stdin_data: JSON.generate("keywords" => ["hive workflows"], "site_url" => "https://example.test")
    )

    assert status.success?, stderr
    report = JSON.parse(stdout)
    assert_equal "seo-provider-metrics/v1", report.fetch("schema")
    assert_equal "prompt-only", report.fetch("mode")
    assert report.fetch("providers").values.all? { |provider| provider.fetch("status") == "missing" }
    refute_match(/Bearer|Basic/i, stdout)
  end

  def test_provider_adapter_exposes_only_fixed_reviewable_network_origins
    version_root = "packages/seo-content/1.0.0"
    policy = HoneycombSecurityLint::Policy.load(File.join(ROOT, "policy", "security-lint.yml"))
    files = HoneycombSecurityLint::TextFiles.new(root: ROOT, limits: policy.limits)
                                               .collect(version_root).files
    tool_path = "#{version_root}/tools/provider-metrics.rb"
    tool_files = files.select { |file| file.path == tool_path }
    commands = HoneycombSecurityLint::CommandExtractor.new.extract(
      tool_files,
      version_root: version_root,
      behavior_paths: [tool_path],
      executable_paths: [tool_path]
    )
    observations = HoneycombSecurityLint::NetworkExtractor.new.extract(commands)

    refute observations.any?(&:dynamic)
    assert_equal %w[
      analyticsdata.googleapis.com api.ahrefs.com api.dataforseo.com www.googleapis.com
    ].sort, observations.map(&:host).uniq.sort
  end

  def test_adapted_packages_pin_upstream_provenance_and_attribution
    expected_paths = {
      "writing" => %w[
        plugins/agent-writing/skills/writing/SKILL.md
        plugins/agent-writing/agents/journalist.md
        plugins/agent-writing/agents/writer.md
        plugins/agent-writing/agents/editor.md
      ],
      "seo-content" => %w[
        plugins/agent-seo/skills/seo/SKILL.md
        plugins/agent-seo/commands/seo:research.md
        plugins/agent-seo/commands/seo:fact-check.md
        plugins/agent-seo/commands/seo:humanize.md
        plugins/agent-seo/commands/seo:optimize.md
      ]
    }

    expected_paths.each do |name, paths|
      readme = File.read(package_path(name, "README.md"))
      notice = File.read(package_path(name, "NOTICE.md"))
      assert_includes readme, AGENT_PLUGINS_REVISION
      assert_includes notice, AGENT_PLUGINS_REVISION
      assert_includes notice, "MIT License"
      paths.each { |path| assert_includes readme, path }
    end
  end

  private

  def package_path(name, *parts)
    File.join(ROOT, "packages", name, "1.0.0", *parts)
  end

  def load_workflow(name)
    Psych.safe_load_file(package_path(name, "workflow.yml"), permitted_classes: [], aliases: false)
  end

  def stage_names(workflow)
    workflow.fetch("stages").map { |item| item.fetch("name") }
  end

  def stage(workflow, name)
    workflow.fetch("stages").find { |item| item.fetch("name") == name }
  end

  def executable_slots(workflow)
    workflow.fetch("stages").each_with_object({}) do |item, slots|
      next unless %w[agent council].include?(item.fetch("kind"))

      stage_id = "stages.#{item.fetch("name")}"
      slots[stage_id] = item
      item.fetch("reviewers", []).each do |reviewer|
        slots["#{stage_id}.reviewers.#{reviewer.fetch("name")}"] = reviewer
        assert_equal "reviewer", reviewer.fetch("mapping_role")
      end
      reviser = item.dig("council", "revise")
      slots["#{stage_id}.revise"] = reviser if reviser
    end
  end

  def recursive_keys(value)
    case value
    when Hash
      value.flat_map { |key, child| [key] + recursive_keys(child) }
    when Array
      value.flat_map { |child| recursive_keys(child) }
    else
      []
    end
  end

  def instruction(package, filename)
    File.read(package_path(package, "instructions", filename))
  end

  def package_markdown(package)
    Dir[package_path(package, "**", "*.md")].sort.map { |path| File.read(path) }.join("\n")
  end
end
