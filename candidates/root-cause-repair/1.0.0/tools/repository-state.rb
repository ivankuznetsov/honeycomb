#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"

class RepositoryStateError < StandardError
  attr_reader :code

  def initialize(code, message)
    @code = code
    super(message)
  end
end

class RepositoryStateCapture
  SCHEMA = "honeycomb-repository-state/v1"
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

  def initialize(start_directory)
    @start_directory = start_directory
    @total_bytes = 0
  end

  def call
    state_root, target_root = resolve_roots
    head = capture_head(target_root)
    refs = capture_refs(target_root)
    index, index_entries = capture_index(target_root)
    tracked = capture_worktree_entries(target_root, index_entries)
    untracked = capture_untracked(target_root, index_entries)

    # Re-read repository authority after the filesystem walk. A moving ref or
    # index would otherwise let one report describe two different states.
    fail_changed! unless head == capture_head(target_root)
    fail_changed! unless refs == capture_refs(target_root)
    fail_changed! unless index == capture_index(target_root).first

    # A writer can change a path after its first read without moving HEAD,
    # refs, or the index. A second complete capture prevents one successful
    # report from combining file states that never existed together.
    @total_bytes = 0
    fail_changed! unless tracked == capture_worktree_entries(target_root, index_entries)
    fail_changed! unless untracked == capture_untracked(target_root, index_entries)
    fail_changed! unless head == capture_head(target_root)
    fail_changed! unless refs == capture_refs(target_root)
    fail_changed! unless index == capture_index(target_root).first

    report = {
      "schema" => SCHEMA,
      "status" => "ok",
      "target" => {
        "root_digest" => sha256_record(File.realpath(target_root).b),
        "state_root_digest" => sha256_record(File.realpath(state_root).b)
      },
      "head" => head,
      "refs" => refs,
      "index" => index,
      "tracked_worktree" => tracked,
      "untracked_worktree" => untracked
    }
    report["fingerprint"] = "sha256:#{Digest::SHA256.hexdigest(canonical_json(report))}"
    canonicalize(report)
  end

  private

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
    {"count" => records.length, "digest" => digest_records(records)}
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
    left.dev == right.dev && left.ino == right.ino && left.mode == right.mode &&
      left.size == right.size && left.mtime == right.mtime && left.ctime == right.ctime
  end

  def safe_text(bytes)
    text = bytes.b.dup.force_encoding(Encoding::UTF_8)
    text.valid_encoding? ? text : "hex:#{bytes.unpack1('H*')}"
  end

  def fail_changed!
    raise RepositoryStateError.new("state_changed", "repository changed during capture")
  end

  def canonical_json(value)
    JSON.generate(canonicalize(value))
  end

  def canonicalize(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) { |key, result| result[key] = canonicalize(value.fetch(key)) }
    when Array
      value.map { |item| canonicalize(item) }
    else
      value
    end
  end
end

begin
  result = RepositoryStateCapture.new(Dir.pwd).call
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
