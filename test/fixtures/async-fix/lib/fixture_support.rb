# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "../../../../lib/honeycomb_registry/atomic_write"

module AsyncFixFixtureSupport
  REQUIRED_PROOFS = %w[
    source_checkouts_read_only
    suggested_medium
    override_accepted
    daemon_pr_opened
    rerun_idempotent
    recoverable_create_failure
    manual_retry_adopted
    provider_github_network_default_deny
    release_cloudflare_registry_default_deny
    synthetic_github_identity_local_transport
  ].freeze
  TOKEN_KEYS = %w[
    ANTHROPIC_API_KEY
    CLAUDE_CODE_OAUTH_TOKEN
    CODEX_API_KEY
    GH_ENTERPRISE_TOKEN
    GH_TOKEN
    GITHUB_ENTERPRISE_TOKEN
    GITHUB_TOKEN
    OPENAI_API_KEY
    XAI_API_KEY
  ].freeze

  module_function

  def root
    home = File.expand_path(ENV.fetch("HOME", ""))
    if File.basename(home) == "home" && File.basename(File.dirname(home)) == "async-fix-smoke"
      return File.dirname(home)
    end

    File.join(ENV.fetch("TMPDIR", "/tmp"), "async-fix-smoke")
  end

  def logs
    File.join(root, "logs")
  end

  def state
    File.join(root, "state")
  end

  def target_bare
    File.join(root, "target.git")
  end

  def registry
    File.join(root, "registry")
  end

  def real_git
    ENV.fetch("ASYNC_FIX_REAL_GIT", "/usr/bin/git")
  end

  def append_log(name, payload)
    FileUtils.mkdir_p(logs, mode: 0o700)
    path = File.join(logs, name)
    File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      file.puts(JSON.generate(payload))
    end
  end

  def deny(fixture, argv, message: "default-deny fixture rejected command")
    append_log("denied.jsonl", {
      "fixture" => fixture,
      "argv" => argv.map(&:to_s),
      "exit_code" => 97
    })
    warn "async-fix #{fixture} default-deny: #{message}"
    exit 97
  end

  def assert_no_tokens!(fixture)
    present = TOKEN_KEYS.select { |key| !ENV[key].to_s.empty? }
    return if present.empty?

    deny(fixture, present, message: "credential environment was not scrubbed")
  end

  def existing_within_root?(path)
    contained_realpath?(File.realpath(path))
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, TypeError
    false
  end

  def writable_within_root?(path)
    expanded = File.expand_path(path.to_s)
    return false unless lexically_within_root?(expanded)
    return false if File.symlink?(expanded)
    return existing_within_root?(expanded) if File.exist?(expanded)

    ancestor = File.dirname(expanded)
    ancestor = File.dirname(ancestor) until File.exist?(ancestor) || ancestor == File.dirname(ancestor)
    contained_realpath?(File.realpath(ancestor))
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, TypeError
    false
  end

  def lexically_within_root?(expanded)
    root_path = File.expand_path(root)
    expanded == root_path || expanded.start_with?("#{root_path}/")
  end

  def contained_realpath?(candidate)
    root_path = File.realpath(root)
    candidate == root_path || candidate.start_with?("#{root_path}/")
  end

  def read_json(path, fallback)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT
    fallback
  rescue JSON::ParserError
    deny("fixture-state", [path], message: "fixture state is malformed")
  end

  def write_json(path, value)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    HoneycombRegistry::AtomicWrite.replace(path, JSON.generate(value), mode: 0o600)
  end
end
