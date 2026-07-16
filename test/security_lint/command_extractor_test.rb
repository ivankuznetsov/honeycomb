# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintCommandExtractorTest < Minitest::Test
  ROOT_PATH = "packages/example/1.0.0"

  def source(relative, text)
    HoneycombSecurityLint::TextFiles::Source.new(
      path: "#{ROOT_PATH}/#{relative}", absolute_path: "/unread", bytes: text, text: text,
      sha256: Digest::SHA256.hexdigest(text)
    )
  end

  def test_extracts_shell_and_untagged_fences_inline_commands_and_yaml_strings
    markdown = <<~MARKDOWN
      prose `not a command` and `curl https://example.test/a`
      ```bash
      wget https://example.test/b
      echo done
      ```
      ```
      plain prose
      pwsh -File setup.ps1
      ```
    MARKDOWN
    yaml = <<~YAML
      task: |
        curl https://example.test/c
        echo complete
      enabled: true
      retries: 2
      values:
        - "git status"
    YAML
    commands = HoneycombSecurityLint::CommandExtractor.new.extract(
      [source("README.md", markdown), source("instructions/run.yml", yaml)], version_root: ROOT_PATH
    )

    assert_equal 7, commands.length
    assert_includes commands.map(&:kind), "inline"
    assert_includes commands.map(&:kind), "fenced"
    assert_includes commands.map(&:kind), "yaml-string"
    refute commands.any? { |command| command.raw == "not a command" }
    refute commands.any? { |command| command.raw == "true" || command.raw == "2" }
  end

  def test_scope_excludes_arbitrary_files_and_non_instruction_extensions
    files = [source("notes.md", "`curl https://bad.test`"), source("instructions/code.rb", "curl https://bad.test")]
    assert_empty HoneycombSecurityLint::CommandExtractor.new.extract(files, version_root: ROOT_PATH)
  end

  def test_malformed_yaml_fails_closed
    assert_raises(HoneycombSecurityLint::CommandExtractor::Invalid) do
      HoneycombSecurityLint::CommandExtractor.new.extract(
        [source("workflow.yml", "stages: [\n")], version_root: ROOT_PATH
      )
    end
  end

  def test_secret_bearing_command_evidence_is_redacted
    secret = "ghp_" + "A" * 24
    commands = HoneycombSecurityLint::CommandExtractor.new.extract(
      [source("README.md", "`curl -H 'token: #{secret}' https://example.test`\n")], version_root: ROOT_PATH
    )

    refute_includes JSON.generate(commands.map(&:evidence)), secret
  end
end
