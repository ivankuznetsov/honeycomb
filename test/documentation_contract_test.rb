# frozen_string_literal: true

require_relative "test_helper"
require "date"

class DocumentationContractTest < Minitest::Test
  MARKDOWN_ARTIFACTS = %w[
    CONTRIBUTING.md
    SECURITY.md
    docs/TRUST.md
    docs/REVIEWS.md
  ].freeze
  ISSUE_FORM = ".github/ISSUE_TEMPLATE/security-delisting.yml"
  REVIEW_KEYS = %w[
    reviewer name version source_sha release_sha256 head_sha reviewed_at verdict
    conflict_of_interest
  ].freeze
  REVIEW_HEADINGS = ["Scope reviewed", "Permission observations", "Findings", "Rationale"].freeze
  REVIEW_VERDICTS = %w[approve approve-with-notes warn reject].freeze
  HEAD_PATTERN = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/

  def test_canonical_artifacts_exist_and_all_links_resolve
    paths = MARKDOWN_ARTIFACTS + [ISSUE_FORM]
    paths.each { |path| assert File.file?(File.join(ROOT, path)), path }

    MARKDOWN_ARTIFACTS.each do |path|
      text = File.read(File.join(ROOT, path))
      text.scan(%r{!?\[[^\]]*\]\(([^)\s]+)\)}m).flatten.each do |target|
        validate_link(path, target)
      end
      text.scan(%r{\b([A-Za-z][A-Za-z0-9+.-]*://[^\s)>]+)}).flatten.each do |url|
        assert url.start_with?("https://"), "#{path}: external URL must use HTTPS: #{url}"
      end
    end
    issue_source = File.read(File.join(ROOT, ISSUE_FORM)).gsub("\\n", "\n")
    issue_source.scan(%r{\b([A-Za-z][A-Za-z0-9+.-]*://[^\s)>]+)}).flatten.each do |url|
      assert url.start_with?("https://"), "#{ISSUE_FORM}: external URL must use HTTPS: #{url}"
    end
  end

  def test_public_issue_form_is_safe_and_complete
    form = HoneycombRegistry::SafeYAML.load_file(File.join(ROOT, ISSUE_FORM))
    assert_equal %w[body description name title], form.keys.sort
    assert_kind_of Array, form.fetch("body")
    warning = form.fetch("body").first
    assert_equal "markdown", warning.fetch("type")
    warning_text = warning.dig("attributes", "value")
    assert_includes warning_text, "issue is public"
    assert_includes warning_text, "Do not include secrets"
    assert_includes warning_text, "private vulnerability reporting"

    identified = form.fetch("body").filter_map { |item| item["id"] }
    assert_equal identified.uniq, identified
    assert_equal %w[
      honeycomb_name honeycomb_version identities report_category observed_behavior
      evidence_links impact requested_action relationship_and_conflicts safe_to_publish
    ], identified
    refute form.key?("labels"), "the issue form must not depend on undeclared labels"

    evidence_index = form.fetch("body").index { |item| item["id"] == "evidence_links" }
    assert_operator evidence_index, :>, 0
    form.fetch("body").each do |item|
      next unless item["id"] && item["type"] != "checkboxes"

      assert_equal true, item.dig("validations", "required"), item.fetch("id")
    end
    confirmation = form.fetch("body").find { |item| item["id"] == "safe_to_publish" }
    assert_equal "checkboxes", confirmation.fetch("type")
    assert confirmation.dig("attributes", "options").all? { |option| option["required"] == true }
  end

  def test_review_fixtures_use_the_strict_record_contract
    verdicts = review_fixture_paths.map do |path|
      front, body = parse_review(path)
      validate_review!(path, front, body)
      front.fetch("verdict")
    end

    assert_equal REVIEW_VERDICTS.sort, verdicts.sort

    review_policy = File.read(File.join(ROOT, "docs", "REVIEWS.md"))
    template = review_policy.match(/```markdown\n(?<review>---\n.*?\n---\n.*)\n```/m)
    refute_nil template, "docs/REVIEWS.md must contain the checked record template"
    template_path = File.join(ROOT, "reviews", "example", "1.0.0", "github-user.md")
    front, body = parse_review_text(template[:review], template_path)
    validate_review!(template_path, front, body)
  end

  def test_review_contract_rejects_invalid_identity_shape_and_sections
    path = review_fixture_paths.first
    original, body = parse_review(path)
    mutations = [
      ->(front) { front.delete("reviewer") },
      ->(front) { front["reviewer"] = "someone-else" },
      ->(front) { front["source_sha"] = "not-a-sha" },
      ->(front) { front["release_sha256"] = "abc" },
      ->(front) { front["head_sha"] = "stale" },
      ->(front) { front["reviewed_at"] = "yesterday" },
      ->(front) { front["verdict"] = "strong-approve" },
      ->(front) { front["conflict_of_interest"] = "" },
      ->(front) { front["unexpected"] = true }
    ]

    mutations.each do |mutation|
      front = Marshal.load(Marshal.dump(original))
      mutation.call(front)
      assert_raises(ArgumentError) { validate_review!(path, front, body) }
    end
    assert_raises(ArgumentError) do
      validate_review!(path, original, body.sub(/^## Scope reviewed$.*?(?=^## )/m, ""))
    end
    assert_raises(HoneycombRegistry::SafeYAML::Invalid) do
      HoneycombRegistry::SafeYAML.load("reviewer: one\nreviewer: two\n", path: "duplicate-review.yml")
    end
  end

  def test_review_identities_and_enums_match_landed_schemas
    catalog = JSON.parse(File.read(File.join(ROOT, "schemas", "catalog-v1.json")))
    listing = JSON.parse(File.read(File.join(ROOT, "schemas", "listing-evidence-v1.json")))
    catalog_entry = catalog.dig("$defs", "entry", "properties")
    listing_record = listing.dig("$defs", "record", "properties")
    lint = listing.dig("$defs", "lint", "properties")
    approval = listing.dig("$defs", "approval", "properties")
    verification = listing.dig("$defs", "verification", "properties")

    assert catalog_entry.key?("source_sha")
    %w[name version].each { |field| assert listing_record.key?(field), field }
    %w[release_sha256 head_sha].each { |field| assert lint.key?(field), field }
    %w[reviewer reviewed_at].each { |field| assert approval.key?(field), field }
    assert_equal %w[archive_sha256 attestation signature verified_at], verification.keys.sort
    assert_equal %w[identity issuer url], verification.dig("signature", "properties").keys.sort
    assert_equal %w[repository url workflow], verification.dig("attestation", "properties").keys.sort
    assert_equal HoneycombRegistry::ListingEvidence::STATES,
                 listing.dig("$defs", "record", "properties", "state", "enum")

    trust = File.read(File.join(ROOT, "docs", "TRUST.md"))
    security = File.read(File.join(ROOT, "SECURITY.md"))
    reviews = File.read(File.join(ROOT, "docs", "REVIEWS.md"))
    HoneycombRegistry::ListingEvidence::STATES.each do |state|
      assert_includes trust, "`#{state}`"
      assert_includes security, "`#{state}`"
    end
    REVIEW_VERDICTS.each { |verdict| assert_includes reviews, "`#{verdict}`" }
  end

  def test_numeric_targets_and_policy_boundaries_are_consistent
    contributing = normalized(File.read(File.join(ROOT, "CONTRIBUTING.md")))
    security = normalized(File.read(File.join(ROOT, "SECURITY.md")))
    reviews = normalized(File.read(File.join(ROOT, "docs", "REVIEWS.md")))
    trust = normalized(File.read(File.join(ROOT, "docs", "TRUST.md")))

    assert_includes contributing, "two business days"
    assert_includes contributing, "seven business days"
    assert_includes contributing, "best-effort targets"
    assert_includes contributing, "`permission_risk: high` version requires two distinct"
    assert_includes security, "48 hours"
    assert_includes security, "seven calendar days"
    assert_includes security, "not resolution deadlines"
    assert_includes security, "immediate `soft_hidden`"
    assert_includes reviews, "informational records"
    assert_includes reviews, "never satisfy security lint"
    assert_includes trust, "public community review"
    assert_includes trust, "remain open source"

    package_format = normalized(File.read(File.join(ROOT, "docs", "PACKAGE_FORMAT.md")))
    assert_match(/`reviews_url` \|[^|]*external[^|]*`reviews\/<name>\/<version>\/`/i,
                 package_format)
  end

  private

  def validate_link(source_path, target)
    return assert(target.start_with?("https://"), "#{source_path}: external link must use HTTPS: #{target}") if target.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/)

    relative, fragment = target.split("#", 2)
    target_path = relative.empty? ? source_path : File.expand_path(relative, File.dirname(File.join(ROOT, source_path)))
    target_path = File.expand_path(target_path, ROOT) unless target_path.start_with?(File::SEPARATOR)
    assert File.exist?(target_path), "#{source_path}: missing local link target #{target}"
    return unless fragment && !fragment.empty?

    assert File.file?(target_path), "#{source_path}: anchor target is not a file: #{target}"
    anchors = File.read(target_path).scan(/^\#{1,6}\s+(.+?)\s*#*\s*$/).flatten.map { |heading| github_anchor(heading) }
    assert_includes anchors, fragment, "#{source_path}: missing anchor #{target}"
  end

  def github_anchor(heading)
    heading.downcase.gsub(/[`*_~]/, "").gsub(/[^\p{Alnum}\s-]/, "").strip.gsub(/\s+/, "-")
  end

  def review_fixture_paths
    Dir[File.join(ROOT, "test", "fixtures", "documentation", "reviews", "**", "*.md")].sort
  end

  def parse_review(path)
    parse_review_text(File.read(path), path)
  end

  def parse_review_text(text, path)
    match = text.match(/\A---\n(?<front>.*?)\n---\n(?<body>.*)\z/m)
    raise ArgumentError, "#{path}: missing strict front matter" unless match

    [HoneycombRegistry::SafeYAML.load(match[:front], path: path), match[:body]]
  end

  def validate_review!(path, front, body)
    raise ArgumentError, "review front matter must be an object" unless front.is_a?(Hash)
    raise ArgumentError, "review keys do not match" unless front.keys.sort == REVIEW_KEYS.sort

    parts = path.split(File::SEPARATOR)
    index = parts.rindex("reviews")
    name, version, filename = parts.values_at(index + 1, index + 2, index + 3)
    reviewer = File.basename(filename, ".md")
    raise ArgumentError, "reviewer mismatch" unless front["reviewer"] == reviewer
    raise ArgumentError, "name mismatch" unless front["name"] == name
    raise ArgumentError, "version mismatch" unless front["version"] == version
    HoneycombRegistry::SemVer.parse(front.fetch("version"))
    raise ArgumentError, "invalid source SHA" unless HEAD_PATTERN.match?(front.fetch("source_sha"))
    raise ArgumentError, "invalid release fingerprint" unless SHA256_PATTERN.match?(front.fetch("release_sha256"))
    raise ArgumentError, "invalid reviewed head" unless HEAD_PATTERN.match?(front.fetch("head_sha"))
    date = Date.iso8601(front.fetch("reviewed_at"))
    raise ArgumentError, "noncanonical review date" unless date.iso8601 == front.fetch("reviewed_at")
    raise ArgumentError, "unknown verdict" unless REVIEW_VERDICTS.include?(front.fetch("verdict"))
    conflict = front.fetch("conflict_of_interest")
    raise ArgumentError, "missing conflict disclosure" unless conflict.is_a?(String) && !conflict.strip.empty?

    headings = body.scan(/^## (.+)$/).flatten
    raise ArgumentError, "review headings do not match" unless headings == REVIEW_HEADINGS
    REVIEW_HEADINGS.each do |heading|
      section = body.match(/^## #{Regexp.escape(heading)}\n+(.*?)(?=^## |\z)/m)
      raise ArgumentError, "empty review section #{heading}" unless section && !section[1].strip.empty?
    end
  rescue KeyError, Date::Error, HoneycombRegistry::SemVer::Invalid => e
    raise ArgumentError, e.message
  end

  def normalized(text)
    text.gsub(/\s+/, " ")
  end
end
