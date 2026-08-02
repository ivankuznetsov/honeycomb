#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"

class RepositoryStateError < StandardError
  attr_reader :code

  def initialize(code, message)
    @code = code
    super(message)
  end
end

module RepositoryAuthority
  CLASSIFICATIONS = %w[relevant unrelated ambiguous].freeze
  RELEVANT_PREFIXES = %w[refs/bisect/ refs/worktree/ refs/rewritten/].freeze
  UNRELATED_PREFIXES = %w[refs/remotes/ refs/llm-wiki/sources/].freeze

  module_function

  def classify_ref(name, symbolic_head)
    return "relevant" if name == symbolic_head
    return "relevant" if RELEVANT_PREFIXES.any? { |prefix| name.start_with?(prefix) }
    return "unrelated" if name.start_with?("refs/heads/")
    return "unrelated" if UNRELATED_PREFIXES.any? { |prefix| name.start_with?(prefix) }

    "ambiguous"
  end

  def ref_deltas(before, after)
    before_by_name = before.to_h { |record| [record.fetch("name"), record] }
    after_by_name = after.to_h { |record| [record.fetch("name"), record] }
    (before_by_name.keys | after_by_name.keys).sort.filter_map do |name|
      previous = before_by_name[name]
      current = after_by_name[name]
      next if previous == current

      {
        "after" => current && ref_identity(current),
        "before" => previous && ref_identity(previous),
        "name" => name
      }
    end
  end

  def ref_identity(record)
    {"oid" => record.fetch("oid"), "type" => record.fetch("type")}
  end

  def canonical_json(value)
    JSON.generate(canonicalize(value))
  end

  def canonicalize(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) do |key, result|
        result[key] = canonicalize(value.fetch(key))
      end
    when Array
      value.map { |item| canonicalize(item) }
    else
      value
    end
  end

  def write_all(io, bytes)
    offset = 0
    while offset < bytes.bytesize
      written = io.write(bytes.byteslice(offset, bytes.bytesize - offset))
      unless written&.positive?
        raise RepositoryStateError.new("checkpoint_write_failed", "checkpoint write made no progress")
      end

      offset += written
    end
    offset
  end

  def same_file_state?(left, right)
    left.dev == right.dev && left.ino == right.ino && left.mode == right.mode &&
      left.size == right.size && left.mtime == right.mtime && left.ctime == right.ctime
  end
end

class RepositoryStateCapture
  SCHEMA = "honeycomb-repository-state/v2"
  MAX_ENTRY_BYTES = 16 * 1024 * 1024
  MAX_TOTAL_BYTES = 256 * 1024 * 1024
  MAX_ENTRIES = 100_000
  READ_CHUNK_BYTES = 1024 * 1024
  MAX_GIT_STDOUT_BYTES = MAX_TOTAL_BYTES
  MAX_GIT_STDERR_BYTES = MAX_ENTRY_BYTES
  GIT_TIMEOUT_SECONDS = 60
  EXCLUDED_PREFIXES = [".git".b, ".hive-state".b].freeze
  GIT_ENV = {
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_OPTIONAL_LOCKS" => "0",
    "GIT_TERMINAL_PROMPT" => "0",
    "LC_ALL" => "C"
  }.freeze

  def initialize(start_directory, capture_boundary: nil)
    @start_directory = start_directory
    @capture_boundary = capture_boundary
    @total_bytes = 0
    @measurement_ref_changes = []
  end

  def call
    state_root, target_root = resolve_roots
    head = capture_head(target_root)
    refs = capture_refs(target_root)
    index, index_entries = capture_index(target_root)
    tracked = capture_worktree_entries(target_root, index_entries)
    untracked = capture_untracked(target_root, index_entries)
    @capture_boundary&.call

    # Re-read repository authority after the filesystem walk. A moving ref or
    # index would otherwise let one report describe two different states.
    fail_changed! unless head == capture_head(target_root)
    refs = reconcile_ref_measurement!(refs, capture_refs(target_root), head)
    fail_changed! unless index == capture_index(target_root).first

    # A writer can change a path after its first read without moving HEAD,
    # refs, or the index. A second complete capture prevents one successful
    # report from combining file states that never existed together.
    @total_bytes = 0
    fail_changed! unless tracked == capture_worktree_entries(target_root, index_entries)
    fail_changed! unless untracked == capture_untracked(target_root, index_entries)
    fail_changed! unless head == capture_head(target_root)
    refs = reconcile_ref_measurement!(refs, capture_refs(target_root), head)
    fail_changed! unless index == capture_index(target_root).first

    report = {
      "target" => {
        "root_digest" => sha256_record(File.realpath(target_root).b),
        "state_root_digest" => sha256_record(File.realpath(state_root).b)
      },
      "head" => head,
      "refs" => ref_summary(refs).merge("records" => refs),
      "index" => index,
      "tracked_worktree" => tracked,
      "untracked_worktree" => untracked,
      "measurement_ref_changes" => @measurement_ref_changes.uniq.sort
    }
    identity = report.reject { |key, _value| key == "measurement_ref_changes" }
    report["fingerprint"] = "sha256:#{Digest::SHA256.hexdigest(RepositoryAuthority.canonical_json(identity))}"
    RepositoryAuthority.canonicalize(report)
  end

  def resolve_roots
    state_root = git_toplevel(@start_directory, "state_root_invalid", "invocation is not inside a Git-backed .hive-state")
    unless File.basename(state_root.b) == ".hive-state".b
      raise RepositoryStateError.new("state_root_invalid", "nested Git root is not .hive-state")
    end

    target_root = File.dirname(state_root)
    target_git_root = git_toplevel(target_root, "target_not_git", "target is not a usable Git worktree")
    unless same_real_path?(target_root, target_git_root)
      raise RepositoryStateError.new("target_not_git", "parent of .hive-state is not the target Git root")
    end

    [state_root, target_git_root]
  end

  private

  def capture_head(root)
    commit = git!(root, "rev-parse", "--verify", "HEAD^{commit}",
                  code: "head_unavailable", message: "HEAD does not resolve to a commit").strip
    unless commit.match?(/\A[0-9a-f]{40,64}\z/)
      raise RepositoryStateError.new("capture_failed", "HEAD commit has an unsupported representation")
    end

    symbolic_output, _error, symbolic_status = git(root, "symbolic-ref", "-q", "HEAD")
    symbolic = if symbolic_status.success?
                 safe_text(symbolic_output.strip)
               elsif symbolic_status.exitstatus == 1
                 nil
               else
                 raise RepositoryStateError.new("head_unavailable", "symbolic HEAD cannot be read")
               end

    {"commit" => commit, "symbolic" => symbolic}
  end

  def capture_refs(root)
    output = git!(root, "for-each-ref", "--format=%(refname)%09%(objectname)%09%(objecttype)", "refs",
                  code: "refs_unavailable", message: "local refs cannot be enumerated")
    records = output.lines(chomp: true).map do |line|
      fields = line.split("\t".b, 3)
      unless fields.length == 3 && fields[1].match?(/\A[0-9a-f]{40,64}\z/)
        raise RepositoryStateError.new("capture_failed", "a local ref has an unsupported representation")
      end
      fields
    end
    records.sort_by!(&:first)
    ensure_entry_count!(records.length)
    records.map do |name, object_id, object_type|
      {"name" => safe_text(name), "oid" => object_id, "type" => safe_text(object_type)}
    end
  end

  def ref_summary(records)
    fields = records.map { |record| [record.fetch("name"), record.fetch("oid"), record.fetch("type")] }
    {"count" => records.length, "digest" => digest_records(fields)}
  end

  def reconcile_ref_measurement!(before, after, head)
    changes = RepositoryAuthority.ref_deltas(before, after)
    blocking = changes.reject do |change|
      RepositoryAuthority.classify_ref(change.fetch("name"), head.fetch("symbolic")) == "unrelated"
    end
    fail_changed! unless blocking.empty?

    @measurement_ref_changes.concat(changes.map { |change| change.fetch("name") })
    after
  end

  def capture_index(root)
    ensure_default_index_flags!(root)
    output = git!(root, "ls-files", "--stage", "-z",
                  code: "index_unavailable", message: "index entries cannot be enumerated")
    entries = output.split("\0".b, -1)
    entries.pop if entries.last == "".b
    parsed = entries.map do |entry|
      match = /\A([0-7]{6}) ([0-9a-f]{40,64}) ([0-3])\t(.*)\z/m.match(entry)
      raise RepositoryStateError.new("entry_unsupported", "index entry has an unsupported representation") unless match

      mode, object_id, stage, path = match.captures
      next if excluded_path?(path)
      raise RepositoryStateError.new("entry_unsupported", "unmerged index entries are unsupported") unless stage == "0"

      validate_relative_path!(path)
      [path.b, mode, object_id, stage]
    end.compact
    parsed.sort_by!(&:first)
    ensure_entry_count!(parsed.length)
    summary = {
      "count" => parsed.length,
      "digest" => digest_records(parsed)
    }
    [summary, parsed]
  end

  def capture_worktree_entries(root, index_entries)
    accumulator = record_accumulator
    index_entries.each do |path, index_mode, object_id, _stage|
      if index_mode == "160000"
        capture_submodule(root, path, object_id, accumulator)
      else
        capture_path(root, path, accumulator, tracked: true)
      end
    end
    accumulator_summary(accumulator)
  end

  def capture_untracked(root, index_entries)
    submodule_paths = index_entries.filter_map { |path, mode, _object_id, _stage| path if mode == "160000" }.to_h { |path| [path, true] }
    ignored_paths = capture_ignored_paths(root)
    scan_for_unsupported_entries(root, "".b, submodule_paths, ignored_paths, 0)

    output = git!(root, "ls-files", "--others", "--exclude-standard", "-z",
                  code: "untracked_unavailable", message: "untracked entries cannot be enumerated")
    paths = output.split("\0".b, -1)
    paths.pop if paths.last == "".b
    paths.reject! { |path| excluded_path?(path) }
    paths.each { |path| validate_relative_path!(path) }
    paths.sort!
    ensure_entry_count!(paths.length)

    accumulator = record_accumulator
    paths.each { |path| capture_path(root, path, accumulator, tracked: false) }
    accumulator_summary(accumulator)
  end

  def capture_ignored_paths(root)
    output = git!(root, "ls-files", "--others", "--ignored", "--exclude-standard",
                  "--directory", "--no-empty-directory", "-z",
                  code: "untracked_unavailable", message: "ignore rules cannot be evaluated")
    paths = output.split("\0".b, -1)
    paths.pop if paths.last == "".b
    ensure_entry_count!(paths.length)
    paths.each_with_object({}) do |path, ignored|
      path = path.delete_suffix("/".b)
      next if excluded_path?(path)

      validate_relative_path!(path)
      ignored[path] = true
    end
  end

  def scan_for_unsupported_entries(root, relative_directory, submodule_paths, ignored_paths, count)
    directory = relative_directory.empty? ? root.b : safe_path(root, relative_directory)
    names = []
    Dir.each_child(directory, encoding: Encoding::BINARY) do |name|
      names << name
      ensure_entry_count!(count + names.length)
    end
    names.sort!
    names.each do |name|
      relative_path = relative_directory.empty? ? name.b : File.join(relative_directory, name.b)
      next if excluded_path?(relative_path) || excluded_component?(name)
      next if submodule_paths.key?(relative_path)
      next if ignored_paths.key?(relative_path)

      count += 1
      ensure_entry_count!(count)
      path = File.join(root.b, relative_path)
      stat = File.lstat(path)
      if stat.directory?
        count = scan_for_unsupported_entries(root, relative_path, submodule_paths, ignored_paths, count)
      elsif !stat.file? && !stat.symlink?
        raise RepositoryStateError.new("entry_unsupported", "only regular files and symlinks are supported")
      end
    rescue Errno::ENOENT, Errno::ENOTDIR
      fail_changed!
    rescue Errno::EACCES, Errno::EPERM
      raise RepositoryStateError.new("entry_unreadable", "an entry cannot be inspected")
    end
    count
  end

  def capture_path(root, relative_path, accumulator, tracked:)
    path = safe_path(root, relative_path)
    stat = begin
      File.lstat(path)
    rescue Errno::ENOENT, Errno::ENOTDIR
      if tracked
        accumulator_add(accumulator, [relative_path, "deleted"])
        return
      end
      fail_changed!
    rescue Errno::EACCES, Errno::EPERM
      raise RepositoryStateError.new("entry_unreadable", "an entry cannot be inspected")
    end

    mode = format("%04o", stat.mode & 0o7777)
    if stat.symlink?
      target = begin
        File.readlink(path).b
      rescue SystemCallError
        raise RepositoryStateError.new("entry_unreadable", "a symlink target cannot be read")
      end
      account_bytes!(target.bytesize)
      accumulator_add(accumulator, [relative_path, "symlink", mode, target.bytesize.to_s, sha256_record(target)])
    elsif stat.file?
      content_digest = digest_file(path, stat)
      accumulator_add(accumulator, [relative_path, "file", mode, stat.size.to_s, content_digest])
    else
      raise RepositoryStateError.new("entry_unsupported", "only regular files and symlinks are supported")
    end
  end

  def capture_submodule(root, relative_path, expected_commit, accumulator)
    path = safe_path(root, relative_path)
    stat = File.lstat(path)
    raise RepositoryStateError.new("submodule_unsupported", "submodule is not initialized") unless stat.directory?

    submodule_root = git_toplevel(path, "submodule_unsupported", "submodule is not initialized")
    unless same_real_path?(path, submodule_root)
      raise RepositoryStateError.new("submodule_unsupported", "submodule root is invalid")
    end
    actual_commit = git!(submodule_root, "rev-parse", "--verify", "HEAD^{commit}",
                         code: "submodule_unsupported", message: "submodule HEAD cannot be read").strip
    unless actual_commit == expected_commit
      raise RepositoryStateError.new("submodule_unsupported", "submodule commit differs from the index")
    end

    status = git!(submodule_root, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none",
                  code: "submodule_unsupported", message: "submodule status cannot be read")
    raise RepositoryStateError.new("submodule_unsupported", "dirty submodules are unsupported") unless status.empty?

    _summary, nested_entries = capture_index(submodule_root)
    nested_entries.select { |_path, mode, _object_id, _stage| mode == "160000" }.each do |nested_path, _mode, object_id, _stage|
      capture_submodule(submodule_root, nested_path, object_id, accumulator)
    end
    accumulator_add(accumulator, [relative_path, "submodule", "160000", actual_commit])
  rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::EPERM
    raise RepositoryStateError.new("submodule_unsupported", "submodule is not initialized or readable")
  end

  def digest_file(path, initial_stat)
    raise RepositoryStateError.new("resource_limit", "an entry exceeds the capture size limit") if initial_stat.size > MAX_ENTRY_BYTES
    account_bytes!(initial_stat.size)

    digest = Digest::SHA256.new
    flags = File::RDONLY
    flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
    File.open(path, flags) do |file|
      opened_stat = file.stat
      unless same_file_state?(initial_stat, opened_stat) && opened_stat.file?
        fail_changed!
      end
      bytes_read = 0
      while (chunk = file.read(READ_CHUNK_BYTES))
        bytes_read += chunk.bytesize
        fail_changed! if bytes_read > opened_stat.size
        digest.update(chunk)
      end
      fail_changed! unless same_file_state?(opened_stat, file.stat)
    end
    "sha256:#{digest.hexdigest}"
  rescue Errno::EACCES, Errno::EPERM, Errno::ELOOP
    raise RepositoryStateError.new("entry_unreadable", "an entry cannot be read without following links")
  rescue Errno::ENOENT, Errno::ENOTDIR
    fail_changed!
  end

  def safe_path(root, relative_path)
    validate_relative_path!(relative_path)
    components = relative_path.split("/".b, -1)
    current = root.b
    components[0...-1].each do |component|
      current = File.join(current, component)
      stat = File.lstat(current)
      raise RepositoryStateError.new("entry_unsupported", "symlinked parent directories are unsupported") unless stat.directory? && !stat.symlink?
    rescue Errno::ENOENT, Errno::ENOTDIR
      fail_changed!
    rescue Errno::EACCES, Errno::EPERM
      raise RepositoryStateError.new("entry_unreadable", "an entry parent cannot be inspected")
    end
    File.join(root.b, relative_path)
  end

  def validate_relative_path!(path)
    components = path.b.split("/".b, -1)
    invalid = path.empty? || path.start_with?("/".b) || components.any? { |part| part.empty? || part == ".".b || part == "..".b }
    raise RepositoryStateError.new("entry_unsupported", "an entry path is unsupported") if invalid
  end

  def excluded_path?(path)
    EXCLUDED_PREFIXES.any? { |prefix| path == prefix || path.start_with?("#{prefix}/".b) }
  end

  def excluded_component?(name)
    EXCLUDED_PREFIXES.include?(name.b)
  end

  def git_toplevel(directory, code, message)
    output = git!(directory, "rev-parse", "--show-toplevel", code: code, message: message).strip
    File.realpath(output)
  rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM
    raise RepositoryStateError.new(code, message)
  end

  def git!(directory, *arguments, code:, message:)
    stdout, _stderr, status = git(directory, *arguments)
    raise RepositoryStateError.new(code, message) unless status.success?
    stdout
  end

  def git(directory, *arguments, respect_fsmonitor: false)
    stdout = +"".b
    stderr = +"".b
    status = nil
    command = ["git", "--no-optional-locks"]
    command.concat(["-c", "core.fsmonitor=false"]) unless respect_fsmonitor
    command.concat(["-C", directory, *arguments])
    Open3.popen3(GIT_ENV, *command) do |stdin, stdout_io, stderr_io, wait_thread|
      stdout_io.binmode
      stderr_io.binmode
      stdin.close
      streams = {
        stdout_io => [stdout, MAX_GIT_STDOUT_BYTES],
        stderr_io => [stderr, MAX_GIT_STDERR_BYTES]
      }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GIT_TIMEOUT_SECONDS
      until streams.empty?
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining <= 0
          terminate_git(wait_thread)
          raise RepositoryStateError.new("git_timeout", "Git command exceeded the capture deadline")
        end
        ready = IO.select(streams.keys, nil, nil, remaining)
        unless ready
          terminate_git(wait_thread)
          raise RepositoryStateError.new("git_timeout", "Git command exceeded the capture deadline")
        end
        ready.first.each do |stream|
          chunk = stream.read_nonblock(READ_CHUNK_BYTES, exception: false)
          next if chunk == :wait_readable

          if chunk.nil?
            streams.delete(stream)
            next
          end

          buffer, limit = streams.fetch(stream)
          buffer << chunk
          next if buffer.bytesize <= limit

          terminate_git(wait_thread)
          raise RepositoryStateError.new("resource_limit", "Git output exceeds the capture size limit")
        end
      end
      status = wait_thread.value
    end
    [stdout, stderr, status]
  rescue Errno::ENOENT
    raise RepositoryStateError.new("git_unavailable", "Git is unavailable")
  end

  def terminate_git(wait_thread)
    Process.kill("KILL", wait_thread.pid)
  rescue Errno::ESRCH
    nil
  end

  def ensure_default_index_flags!(root)
    output, _stderr, status = git(root, "ls-files", "-v", "-f", "-z", respect_fsmonitor: true)
    unless status.success?
      raise RepositoryStateError.new("index_unavailable", "index flags cannot be enumerated")
    end
    entries = output.split("\0".b, -1)
    entries.pop if entries.last == "".b
    ensure_entry_count!(entries.length)
    entries.each do |entry|
      match = /\A([A-Za-z?]) (.*)\z/m.match(entry)
      raise RepositoryStateError.new("entry_unsupported", "index flags have an unsupported representation") unless match

      tag, path = match.captures
      next if excluded_path?(path)

      validate_relative_path!(path)
      unless tag == "H"
        raise RepositoryStateError.new("index_flags_unsupported", "non-default index flags are unsupported")
      end
    end
  end

  def record_accumulator
    {digest: Digest::SHA256.new, count: 0}
  end

  def accumulator_add(accumulator, fields)
    accumulator[:count] += 1
    ensure_entry_count!(accumulator[:count])
    update_length_prefixed(accumulator[:digest], fields)
  end

  def accumulator_summary(accumulator)
    {"count" => accumulator[:count], "digest" => "sha256:#{accumulator[:digest].hexdigest}"}
  end

  def digest_records(records)
    digest = Digest::SHA256.new
    records.each { |fields| update_length_prefixed(digest, fields) }
    "sha256:#{digest.hexdigest}"
  end

  def update_length_prefixed(digest, fields)
    digest.update([fields.length].pack("N"))
    fields.each do |field|
      bytes = field.to_s.b
      digest.update([bytes.bytesize].pack("Q>"))
      digest.update(bytes)
    end
  end

  def sha256_record(bytes)
    "sha256:#{Digest::SHA256.hexdigest(bytes)}"
  end

  def account_bytes!(size)
    raise RepositoryStateError.new("resource_limit", "an entry exceeds the capture size limit") if size > MAX_ENTRY_BYTES
    @total_bytes += size
    raise RepositoryStateError.new("resource_limit", "repository exceeds the capture size limit") if @total_bytes > MAX_TOTAL_BYTES
  end

  def ensure_entry_count!(count)
    raise RepositoryStateError.new("resource_limit", "repository exceeds the entry limit") if count > MAX_ENTRIES
  end

  def same_real_path?(left, right)
    File.realpath(left) == File.realpath(right)
  rescue SystemCallError
    false
  end

  def same_file_state?(left, right)
    RepositoryAuthority.same_file_state?(left, right)
  end

  def safe_text(bytes)
    text = bytes.b.dup.force_encoding(Encoding::UTF_8)
    text.valid_encoding? ? text : "hex:#{bytes.unpack1('H*')}"
  end

  def fail_changed!
    raise RepositoryStateError.new("state_changed", "repository changed during capture")
  end

end

class RepositoryAuthorityController
  CHECKPOINT_SCHEMA = "honeycomb-repository-authority-checkpoint/v2"
  CHECKPOINT_NAME = "repository-authority.json"
  MAX_CHECKPOINT_BYTES = RepositoryStateCapture::MAX_GIT_STDOUT_BYTES
  MAX_CHANGED_REF_RECORDS = 50
  EXPECTED_DIGEST = /\Asha256:[0-9a-f]{64}\z/
  TARGET_STATE_KEYS = %w[target head index tracked_worktree untracked_worktree].freeze
  WORKTREE_STATE_KEYS = %w[tracked_worktree untracked_worktree].freeze

  def initialize(start_directory, arguments, capture_boundary: nil)
    @start_directory = File.realpath(start_directory)
    @arguments = arguments.dup
    @capture_boundary = capture_boundary
    @recovered_checkpoint_digest = nil
  rescue SystemCallError
    raise RepositoryStateError.new("state_root_invalid", "invocation directory cannot be resolved")
  end

  def call
    operation = @arguments.shift
    unless %w[create compare inventory advance].include?(operation)
      raise RepositoryStateError.new("usage", "operation must be create, compare, inventory, or advance")
    end

    options = parse_options(operation)
    checkpoint_path = resolve_checkpoint_path
    case operation
    when "create"
      create(checkpoint_path)
    when "compare"
      compare(checkpoint_path, options.fetch(:expect))
    when "inventory"
      inventory(checkpoint_path, options.fetch(:expect))
    when "advance"
      advance(checkpoint_path, options.fetch(:expect), options.fetch(:worktree_digest))
    end
  end

  private

  def parse_options(operation)
    options = {expect: nil, worktree_digest: nil}
    until @arguments.empty?
      argument = @arguments.shift
      case argument
      when "--allow-worktree"
        options[:worktree_digest] = @arguments.shift
      when "--expect"
        options[:expect] = @arguments.shift
      else
        raise RepositoryStateError.new("usage", "unsupported argument")
      end
    end
    if operation == "create"
      if options[:worktree_digest] || options[:expect]
        raise RepositoryStateError.new("usage", "create does not accept comparison options")
      end
    else
      unless options[:expect]&.match?(EXPECTED_DIGEST)
        raise RepositoryStateError.new("usage", "compare, inventory, and advance require --expect sha256:<digest>")
      end
      if operation != "advance" && options[:worktree_digest]
        raise RepositoryStateError.new("usage", "--allow-worktree is valid only for advance")
      end
      if options[:worktree_digest] && !options[:worktree_digest].match?(EXPECTED_DIGEST)
        raise RepositoryStateError.new("usage", "--allow-worktree requires sha256:<digest>")
      end
    end
    options
  end

  def create(path)
    current, retries = capture_with_retry
    if File.exist?(path) || File.symlink?(path)
      checkpoint = load_checkpoint(path, expected_digest: nil, current: current)
      comparison = compare_snapshots(checkpoint.fetch("snapshot"), current)
      unless comparison.fetch("verdict") == "continue"
        raise RepositoryStateError.new("checkpoint_exists", "existing checkpoint does not match target authority")
      end
      return result(
        "create", current, checkpoint,
        comparison.merge("reason" => "checkpoint_existing"), retries
      )
    end

    checkpoint = build_checkpoint(current)
    write_checkpoint(path, checkpoint)
    result(
      "create", current, checkpoint,
      empty_comparison("checkpoint_created"), retries
    )
  end

  def compare(path, expected_digest)
    current, retries = capture_with_retry
    checkpoint = load_checkpoint(path, expected_digest: expected_digest, current: current)
    comparison = compare_snapshots(checkpoint.fetch("snapshot"), current)
    result("compare", current, checkpoint, comparison, retries)
  end

  def inventory(path, expected_digest)
    current, retries = capture_with_retry
    checkpoint = load_checkpoint(path, expected_digest: expected_digest, current: current)
    comparison = compare_snapshots(
      checkpoint.fetch("snapshot"), current, observe_worktree: true
    )
    result("inventory", current, checkpoint, comparison, retries)
  end

  def advance(path, expected_digest, worktree_digest)
    current, retries = capture_with_retry
    checkpoint = load_checkpoint(path, expected_digest: expected_digest, current: current)
    comparison = compare_snapshots(
      checkpoint.fetch("snapshot"), current, worktree_digest: worktree_digest
    )
    return result("advance", current, checkpoint, comparison, retries) unless comparison.fetch("verdict") == "continue"

    advanced = build_checkpoint(current, previous: checkpoint)
    write_checkpoint(path, advanced)
    result(
      "advance", current, advanced,
      comparison.merge(
        "previous_checkpoint_digest" => checkpoint.fetch("digest"),
        "reason" => "checkpoint_advanced"
      ), retries
    )
  end

  def capture_with_retry
    retries = 0
    begin
      [RepositoryStateCapture.new(@start_directory, capture_boundary: @capture_boundary).call, retries]
    rescue RepositoryStateError => error
      raise unless error.code == "state_changed" && retries.zero?

      retries += 1
      retry
    end
  end

  def compare_snapshots(checkpoint, current, worktree_digest: nil, observe_worktree: false)
    changed_worktree_keys = WORKTREE_STATE_KEYS.select do |key|
      checkpoint.fetch(key) != current.fetch(key)
    end
    worktree_changes = summarize_worktree_changes(checkpoint, current, changed_worktree_keys)
    worktree_digest_matches = worktree_digest &&
                              worktree_digest == worktree_changes.fetch("digest")
    worktree_permitted = changed_worktree_keys.empty? || worktree_digest_matches
    target_changes = TARGET_STATE_KEYS.filter_map do |key|
      next if checkpoint.fetch(key) == current.fetch(key)
      next if WORKTREE_STATE_KEYS.include?(key) && (observe_worktree || worktree_permitted)

      key
    end
    pinned_branch = checkpoint.dig("head", "symbolic")
    classified = RepositoryAuthority.ref_deltas(
      checkpoint.dig("refs", "records"), current.dig("refs", "records")
    ).group_by { |change| RepositoryAuthority.classify_ref(change.fetch("name"), pinned_branch) }
    changes = RepositoryAuthority::CLASSIFICATIONS.to_h do |classification|
      [classification, summarize_ref_changes(classified.fetch(classification, []))]
    end
    blocked_reason = if target_changes.any? || changes.dig("relevant", "count").positive?
                       "target_changed"
                     elsif changes.dig("ambiguous", "count").positive?
                       "ambiguous_refs"
                     end
    reason = if blocked_reason
               blocked_reason
             elsif changes.dig("unrelated", "count").positive?
               "unrelated_refs"
             elsif changed_worktree_keys.any?
               "worktree_changes"
             else
               "unchanged"
             end
    {
      "authorized_worktree_changes" => worktree_digest_matches ? changed_worktree_keys : [],
      "changes" => changes,
      "reason" => reason,
      "target_changes" => target_changes,
      "verdict" => blocked_reason ? "blocked" : "continue",
      "worktree_changes" => worktree_changes.merge(
        "authorized" => !!worktree_digest_matches && !observe_worktree,
        "observed" => observe_worktree
      )
    }
  end

  def summarize_worktree_changes(checkpoint, current, changed_keys)
    identities = changed_keys.to_h do |key|
      [key, {"after" => current.fetch(key), "before" => checkpoint.fetch(key)}]
    end
    {
      "count" => changed_keys.length,
      "digest" => digest_value(identities),
      "keys" => changed_keys
    }
  end

  def summarize_ref_changes(changes)
    sorted = changes.sort_by { |change| change.fetch("name") }
    {
      "count" => sorted.length,
      "digest" => digest_value(sorted),
      "records" => sorted.first(MAX_CHANGED_REF_RECORDS),
      "truncated" => sorted.length > MAX_CHANGED_REF_RECORDS
    }
  end

  def empty_comparison(reason)
    {
      "authorized_worktree_changes" => [],
      "changes" => RepositoryAuthority::CLASSIFICATIONS.to_h do |classification|
        [classification, summarize_ref_changes([])]
      end,
      "reason" => reason,
      "target_changes" => [],
      "verdict" => "continue",
      "worktree_changes" => {
        "authorized" => false,
        "count" => 0,
        "digest" => digest_value({}),
        "keys" => [],
        "observed" => false
      }
    }
  end

  def build_checkpoint(snapshot, previous: nil)
    body = {
      "previous_digest" => previous&.fetch("digest"),
      "schema" => CHECKPOINT_SCHEMA,
      "sequence" => previous ? previous.fetch("sequence") + 1 : 0,
      "snapshot" => snapshot
    }
    body.merge("digest" => digest_value(body))
  end

  def load_checkpoint(path, expected_digest:, current:)
    bytes = read_checkpoint(path)

    checkpoint = JSON.parse(bytes)
    unless checkpoint.is_a?(Hash) && checkpoint["schema"] == CHECKPOINT_SCHEMA &&
           checkpoint["snapshot"].is_a?(Hash) && checkpoint["digest"].is_a?(String) &&
           checkpoint["sequence"].is_a?(Integer) && checkpoint["sequence"] >= 0 &&
           (checkpoint["sequence"].zero? ? checkpoint["previous_digest"].nil? :
             checkpoint["previous_digest"]&.match?(EXPECTED_DIGEST))
      raise RepositoryStateError.new("checkpoint_invalid", "checkpoint structure is invalid")
    end
    body = checkpoint.reject { |key, _value| key == "digest" }
    unless checkpoint.fetch("digest") == digest_value(body)
      raise RepositoryStateError.new("checkpoint_invalid", "checkpoint digest is invalid")
    end
    if expected_digest && checkpoint.fetch("digest") != expected_digest
      if checkpoint.fetch("previous_digest") == expected_digest
        @recovered_checkpoint_digest = expected_digest
      else
        raise RepositoryStateError.new("checkpoint_mismatch", "checkpoint does not match stage evidence")
      end
    end
    unless checkpoint.dig("snapshot", "target") == current.fetch("target")
      raise RepositoryStateError.new("checkpoint_invalid", "checkpoint belongs to another target")
    end
    checkpoint
  rescue Errno::ENOENT
    raise RepositoryStateError.new("checkpoint_missing", "repository authority checkpoint is missing")
  rescue Errno::EACCES, Errno::EPERM
    raise RepositoryStateError.new("checkpoint_invalid", "repository authority checkpoint is unreadable")
  rescue JSON::ParserError
    raise RepositoryStateError.new("checkpoint_invalid", "checkpoint JSON is invalid")
  end


  def read_checkpoint(path)
    flags = File::RDONLY
    flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
    File.open(path, flags) do |file|
      before = file.stat
      unless before.file? && !before.symlink?
        raise RepositoryStateError.new("checkpoint_invalid", "checkpoint must be a regular file")
      end
      if before.size > MAX_CHECKPOINT_BYTES
        raise RepositoryStateError.new("checkpoint_invalid", "checkpoint exceeds the size limit")
      end

      bytes = file.read(MAX_CHECKPOINT_BYTES + 1)
      if bytes.bytesize > MAX_CHECKPOINT_BYTES
        raise RepositoryStateError.new("checkpoint_invalid", "checkpoint exceeds the size limit")
      end
      unless RepositoryAuthority.same_file_state?(before, file.stat)
        raise RepositoryStateError.new("checkpoint_invalid", "checkpoint changed while being read")
      end
      bytes
    end
  rescue Errno::ELOOP
    raise RepositoryStateError.new("checkpoint_invalid", "checkpoint must be a regular file")
  end

  def resolve_checkpoint_path
    state_root, = RepositoryStateCapture.new(@start_directory).resolve_roots
    unless @start_directory.start_with?("#{state_root}#{File::SEPARATOR}")
      raise RepositoryStateError.new("checkpoint_path_invalid", "run from a task folder inside .hive-state")
    end

    File.join(@start_directory, CHECKPOINT_NAME)
  end

  def write_checkpoint(path, checkpoint)
    temporary = "#{path}.tmp.#{Process.pid}"
    bytes = "#{RepositoryAuthority.canonical_json(checkpoint)}\n"
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      RepositoryAuthority.write_all(file, bytes)
      file.flush
      unless file.stat.size == bytes.bytesize
        raise RepositoryStateError.new("checkpoint_write_failed", "checkpoint write is incomplete")
      end
      file.fsync
    end
    File.rename(temporary, path)
    sync_directory(File.dirname(path))
  rescue Errno::EEXIST, Errno::EACCES, Errno::EPERM, Errno::ENOENT
    raise RepositoryStateError.new("checkpoint_write_failed", "checkpoint cannot be written atomically")
  ensure
    FileUtils.rm_f(temporary) if temporary
  end

  def sync_directory(path)
    File.open(path, File::RDONLY) { |directory| directory.fsync }
  rescue SystemCallError
    nil
  end

  def result(operation, snapshot, checkpoint, comparison, retries)
    if @recovered_checkpoint_digest && comparison.fetch("verdict") == "continue"
      comparison = comparison.merge("reason" => "checkpoint_recovered")
    end
    public_snapshot = snapshot.reject { |key, _value| key == "measurement_ref_changes" || key == "refs" }
    public_snapshot["refs"] = snapshot.fetch("refs").reject { |key, _value| key == "records" }
    measurement = snapshot.fetch("measurement_ref_changes").map do |name|
      {"name" => name}
    end
    {
      "capture_retries" => retries,
      "changes" => comparison.fetch("changes"),
      "checkpoint" => {
        "digest" => checkpoint.fetch("digest"),
        "previous_digest" => checkpoint.fetch("previous_digest"),
        "sequence" => checkpoint.fetch("sequence"),
        "schema" => checkpoint.fetch("schema")
      },
      "measurement" => summarize_ref_changes(measurement),
      "operation" => operation,
      "reason" => comparison.fetch("reason"),
      "schema" => RepositoryStateCapture::SCHEMA,
      "snapshot" => public_snapshot,
      "status" => "ok",
      "target_changes" => comparison.fetch("target_changes"),
      "authorized_worktree_changes" => comparison.fetch("authorized_worktree_changes"),
      "verdict" => comparison.fetch("verdict"),
      "worktree_changes" => comparison.fetch("worktree_changes")
    }.tap do |output|
      previous = comparison["previous_checkpoint_digest"]
      output["previous_checkpoint_digest"] = previous if previous
      output["recovered_checkpoint_digest"] = @recovered_checkpoint_digest if @recovered_checkpoint_digest
    end
  end

  def digest_value(value)
    "sha256:#{Digest::SHA256.hexdigest(RepositoryAuthority.canonical_json(value))}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    result = RepositoryAuthorityController.new(Dir.pwd, ARGV).call
    STDOUT.write(JSON.generate(result), "\n")
  rescue RepositoryStateError => error
    result = {
      "error" => {"code" => error.code, "message" => error.message},
      "schema" => RepositoryStateCapture::SCHEMA,
      "status" => "error"
    }
    STDOUT.write(JSON.generate(result), "\n")
    exit 1
  rescue StandardError
    result = {
      "error" => {"code" => "capture_failed", "message" => "repository state cannot be captured exactly"},
      "schema" => RepositoryStateCapture::SCHEMA,
      "status" => "error"
    }
    STDOUT.write(JSON.generate(result), "\n")
    exit 1
  end
end
