# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "openssl"
require "optparse"
require "pathname"
require "shellwords"

module HiveVideoProduction
  WORKFLOW_ID = "video-production@0.1.0"
  MEDIA_SCHEMA = "hive-video-production/v1"
  OPTIONAL_INPUTS = %w[
    VIDEO_CAPTURE_PASSWORD
    VIDEO_CAPTURE_TOKEN
    VIDEO_CAPTURE_USERNAME
  ].freeze
  HOST_DEPENDENCIES = %w[docker asciinema agg ffmpeg ffprobe].freeze
  TAKE_PATTERN = /\Atake-[0-9]{4}\z/
  PROCESS_OUTPUT_LIMIT = 65_536
  PROCESS_POLL_SECONDS = 0.02
  TERM_GRACE_SECONDS = 0.5
  KILL_GRACE_SECONDS = 0.5
  READER_GRACE_SECONDS = 0.5
  CONTAINER_CLEANUP_SECONDS = 2
  APPROVAL_FIELD_LABELS = {
    "schema" => "Schema",
    "stage" => "Stage",
    "workflow" => "Workflow",
    "project" => "Project",
    "scene" => "Scene",
    "fingerprint" => "Fingerprint",
    "manifest_sha256" => "Manifest-SHA256",
    "tool_sha256" => "Tool-SHA256",
    "owner_public_key_sha256" => "Owner-Public-Key-SHA256",
    "command_sha256" => "Command-SHA256",
    "image" => "Image",
    "network" => "Network",
    "take" => "Take",
    "take_path" => "Take-Path",
    "staged_snapshot_path" => "Staged-Snapshot",
    "snapshot_sha256" => "Snapshot-SHA256",
    "artifacts" => "Artifacts",
    "verification_sha256" => "Verification-SHA256",
    "capture_context_sha256" => "Capture-Context-SHA256",
    "capture_receipt_sha256" => "Capture-Receipt-SHA256",
    "capture_approval_fingerprint" => "Capture-Approval-Fingerprint",
    "artifact_hashes" => "Artifact-Hashes"
  }.freeze

  class Error < StandardError; end
  class InterruptedCapture < Error; end

  module_function

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def canonical(value)
    case value
    when Hash
      value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array
      value.map { |item| canonical(item) }
    else
      value
    end
  end

  def compact_json(value)
    JSON.generate(canonical(value))
  end

  def json(value)
    JSON.pretty_generate(canonical(value)) + "\n"
  end

  def atomic_write(path, contents, mode: 0o600, overwrite: true)
    directory = File.dirname(path)
    FileUtils.mkdir_p(directory, mode: 0o700)
    raise Error, "refusing to overwrite existing file: #{path}" if !overwrite && File.exist?(path)

    temporary = File.join(directory, ".#{File.basename(path)}.tmp-#{Process.pid}-#{rand(1_000_000)}")
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
      file.write(contents)
      file.flush
      file.fsync
    end
    File.rename(temporary, path)
  ensure
    FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
  end

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  def frame(digest, value)
    bytes = value.to_s.b
    digest << [bytes.bytesize].pack("Q>") << bytes
  end

  def tool_sha256
    root = File.dirname(File.realpath(__FILE__))
    paths = Dir[File.join(root, "*.rb")].sort
    digest = Digest::SHA256.new
    paths.each do |path|
      frame(digest, File.basename(path))
      frame(digest, File.stat(path).mode & 0o111)
      frame(digest, sha256(path))
    end
    digest.hexdigest
  end

  def executable_path(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |directory|
      next if directory.empty?

      candidate = File.join(directory, name)
      candidate if File.file?(candidate) && File.executable?(candidate)
    end.first
  end

  def redact_runtime_values(value)
    OPTIONAL_INPUTS.filter_map { |name| ENV[name] }
                   .reject(&:empty?)
                   .uniq
                   .sort_by { |secret| -secret.bytesize }
                   .reduce(value.b.dup) { |text, secret| text.gsub(secret.b, "[REDACTED]") }
  end

  def snapshot_records(path)
    raise Error, "snapshot must be a non-symlink directory: #{path}" unless File.directory?(path) && !File.symlink?(path)

    entries = Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sort
    entries.reject! { |entry| %w[. ..].include?(File.basename(entry)) }
    entries.map do |entry|
      relative = Pathname.new(entry).relative_path_from(Pathname.new(path)).to_s
      stat = File.lstat(entry)
      raise Error, "snapshot contains a symlink: #{relative}" if stat.symlink?

      if stat.directory?
        ["directory", relative, stat.mode & 0o777, nil, nil]
      elsif stat.file?
        ["file", relative, stat.mode & 0o777, stat.size, sha256(entry)]
      else
        raise Error, "snapshot contains a non-regular entry: #{relative}"
      end
    end
  end

  def snapshot_sha256(path)
    digest = Digest::SHA256.new
    snapshot_records(path).each do |type, relative, mode, size, content_digest|
      frame(digest, type)
      frame(digest, relative)
      frame(digest, mode)
      frame(digest, size || "")
      frame(digest, content_digest || "")
    end
    digest.hexdigest
  end

  def stage_snapshot(source, destination)
    raise Error, "staged snapshot already exists: #{destination}" if File.exist?(destination)

    before = snapshot_sha256(source)
    parent = File.dirname(destination)
    FileUtils.mkdir_p(parent, mode: 0o700)
    temporary = "#{destination}.tmp-#{Process.pid}-#{rand(1_000_000)}"
    Dir.mkdir(temporary, 0o700)
    snapshot_records(source).each do |type, relative, mode, _size, _digest|
      source_path = File.join(source, relative)
      target_path = File.join(temporary, relative)
      if type == "directory"
        FileUtils.mkdir_p(target_path, mode: mode)
        FileUtils.chmod(mode, target_path)
      else
        FileUtils.mkdir_p(File.dirname(target_path), mode: 0o700)
        File.open(source_path, "rb") do |input|
          File.open(target_path, File::WRONLY | File::CREAT | File::EXCL, mode) do |output|
            FileUtils.copy_stream(input, output)
            output.flush
            output.fsync
          end
        end
      end
    end
    after = snapshot_sha256(source)
    staged = snapshot_sha256(temporary)
    raise Error, "snapshot changed while staging" unless before == after && before == staged

    File.rename(temporary, destination)
    before
  ensure
    FileUtils.rm_rf(temporary) if temporary && File.exist?(temporary)
  end

  def paths_overlap?(left, right)
    a = File.expand_path(left)
    b = File.expand_path(right)
    a == b || a.start_with?("#{b}#{File::SEPARATOR}") || b.start_with?("#{a}#{File::SEPARATOR}")
  end

  def public_key(path)
    raise Error, "owner public key must be a non-symlink regular file: #{path}" unless File.file?(path) && !File.symlink?(path)

    bytes = File.binread(path)
    raise Error, "owner public key must not contain private key material" if bytes.include?("PRIVATE KEY")
    key = OpenSSL::PKey.read(bytes)
    raise Error, "owner public key must be Ed25519" unless key.respond_to?(:oid) && key.oid == "ED25519"
    begin
      key.private_to_der
      raise Error, "owner public key must not contain private key material"
    rescue OpenSSL::PKey::PKeyError
      nil
    end

    [key, Digest::SHA256.hexdigest(bytes)]
  rescue OpenSSL::PKey::PKeyError => error
    raise Error, "owner public key is invalid: #{error.message}"
  end

  def bounded_reader(io)
    Thread.new do
      retained = +"".b
      truncated = false
      begin
        loop do
          chunk = io.readpartial(8192)
          remaining = PROCESS_OUTPUT_LIMIT - retained.bytesize
          retained << chunk.byteslice(0, remaining) if remaining.positive?
          truncated ||= chunk.bytesize > remaining
        end
      rescue EOFError, IOError
        nil
      end
      retained << "\n[output truncated after #{PROCESS_OUTPUT_LIMIT} bytes]\n" if truncated
      {bytes: redact_runtime_values(retained), truncated: truncated}
    end
  end

  def wait_for_child(pid, deadline)
    loop do
      begin
        waited = Process.waitpid2(pid, Process::WNOHANG)
        return waited&.last if waited
      rescue Errno::ECHILD
        return nil
      end
      return nil if monotonic >= deadline

      sleep PROCESS_POLL_SECONDS
    end
  end

  def signal_group(pid, signal)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH
    nil
  end

  def process_group_alive?(pid)
    Process.kill(0, -pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def wait_for_process_group(pid, status, deadline)
    loop do
      status ||= wait_for_child(pid, monotonic)
      return [status, true] unless process_group_alive?(pid)
      return [status, false] if monotonic >= deadline

      sleep PROCESS_POLL_SECONDS
    end
  end

  def terminate_child(pid, status = nil)
    status ||= wait_for_child(pid, monotonic)
    return [status, false] unless process_group_alive?(pid)

    signal_group(pid, "TERM")
    status, group_gone = wait_for_process_group(pid, status, monotonic + TERM_GRACE_SECONDS)
    unless group_gone
      signal_group(pid, "KILL")
      status, group_gone = wait_for_process_group(pid, status, monotonic + KILL_GRACE_SECONDS)
    end
    Process.detach(pid) unless status
    [status, !group_gone]
  rescue Errno::ECHILD
    [status, process_group_alive?(pid)]
  end

  def finish_reader(thread, io)
    return [thread.value, false] if thread.join(READER_GRACE_SECONDS)

    io.close unless io.closed?
    return [thread.value, true] if thread.join(READER_GRACE_SECONDS)

    thread.kill
    thread.join(READER_GRACE_SECONDS)
    [{bytes: "[reader cleanup incomplete]\n".b, truncated: true}, true]
  rescue IOError
    [{bytes: "".b, truncated: false}, false]
  end

  def process_capture(arguments, timeout_seconds:)
    stdout_read, stdout_write = IO.pipe
    stderr_read, stderr_write = IO.pipe
    pid = nil
    status = nil
    timed_out = false
    interrupted = false
    cleanup_incomplete = false
    spawn_error = nil
    stdout_thread = nil
    stderr_thread = nil

    begin
      pid = Process.spawn(*arguments, in: File::NULL, out: stdout_write, err: stderr_write, pgroup: true)
      stdout_write.close
      stderr_write.close
      stdout_thread = bounded_reader(stdout_read)
      stderr_thread = bounded_reader(stderr_read)
      deadline = monotonic + timeout_seconds
      status = wait_for_child(pid, deadline)
      if status.nil?
        timed_out = true
        status, incomplete = terminate_child(pid)
        cleanup_incomplete ||= incomplete
      else
        status, incomplete = terminate_child(pid, status)
        cleanup_incomplete ||= incomplete
      end
    rescue Interrupt
      interrupted = true
      status, incomplete = terminate_child(pid) if pid
      cleanup_incomplete ||= incomplete if pid
    rescue SystemCallError => error
      spawn_error = error
      status, incomplete = terminate_child(pid) if pid
      cleanup_incomplete ||= incomplete if pid
    end

    empty_result = {bytes: "".b, truncated: false}
    stdout_result, stdout_incomplete = stdout_thread ? finish_reader(stdout_thread, stdout_read) : [empty_result, false]
    stderr_result, stderr_incomplete = stderr_thread ? finish_reader(stderr_thread, stderr_read) : [empty_result, false]
    cleanup_incomplete ||= stdout_incomplete || stderr_incomplete
    {
      stdout: stdout_result.fetch(:bytes), stderr: stderr_result.fetch(:bytes), status: status,
      timed_out: timed_out, interrupted: interrupted, cleanup_incomplete: cleanup_incomplete,
      truncated: stdout_result.fetch(:truncated) || stderr_result.fetch(:truncated),
      error: spawn_error && "#{spawn_error.class}: #{spawn_error.message}"
    }
  ensure
    [stdout_write, stderr_write, stdout_read, stderr_read].each do |io|
      io&.close unless io&.closed?
    rescue IOError
      nil
    end
  end

  class MediaManifest
    include HiveVideoProduction

    class DuplicateKeyScanner
      def initialize(bytes)
        @bytes = bytes
        @index = 0
      end

      def scan!
        skip_space
        scan_value
      end

      private

      def scan_value
        skip_space
        case current
        when "{" then scan_object
        when "[" then scan_array
        when '"' then scan_string
        else scan_literal
        end
      end

      def scan_object
        @index += 1
        keys = {}
        skip_space
        return @index += 1 if current == "}"
        loop do
          skip_space
          key = scan_string
          raise Error, "duplicate JSON key: #{key}" if keys.key?(key)

          keys[key] = true
          skip_space
          @index += 1
          scan_value
          skip_space
          break @index += 1 if current == "}"

          @index += 1
        end
      end

      def scan_array
        @index += 1
        skip_space
        return @index += 1 if current == "]"
        loop do
          scan_value
          skip_space
          break @index += 1 if current == "]"

          @index += 1
        end
      end

      def scan_string
        start = @index
        @index += 1
        loop do
          case current
          when "\\" then @index += 2
          when '"'
            @index += 1
            return JSON.parse(@bytes.byteslice(start...@index))
          else @index += 1
          end
        end
      end

      def scan_literal
        @index += 1 until current.nil? || current.match?(/[\s,}\]]/)
      end

      def skip_space
        @index += 1 while current&.match?(/\s/)
      end

      def current
        @bytes.getbyte(@index)&.chr
      end
    end

    ROOT_KEYS = %w[capture output_dir project scenes schema].freeze
    CAPTURE_KEYS = %w[environment image network owner_public_key snapshot timeout_seconds].freeze
    SCENE_KEYS = %w[columns command duration_seconds id rows title].freeze
    IMAGE_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._:\/-]*@sha256:[0-9a-f]{64}\z/
    ID_PATTERN = /\A[a-z0-9][a-z0-9-]{1,62}[a-z0-9]\z/

    attr_reader :path, :document

    def initialize(path)
      @path = File.expand_path(path)
      raise Error, "media manifest does not exist: #{@path}" unless File.file?(@path)
      raise Error, "media manifest must not be a symlink: #{@path}" if File.symlink?(@path)

      @bytes = File.binread(@path)
      @document = JSON.parse(@bytes)
      DuplicateKeyScanner.new(@bytes).scan!
      validate!
    rescue JSON::ParserError => error
      raise Error, "media manifest is not valid JSON: #{error.message}"
    end

    def manifest_sha256 = Digest::SHA256.hexdigest(@bytes)
    def project = document.fetch("project")
    def scenes = document.fetch("scenes")
    def capture = document.fetch("capture")
    def output_root = resolve_relative(document.fetch("output_dir"))
    def snapshot_path = resolve_relative(capture.fetch("snapshot"))
    def owner_public_key_path = resolve_relative(capture.fetch("owner_public_key"))

    def scene(id)
      scenes.find { |item| item.fetch("id") == id } || raise(Error, "unknown scene: #{id}")
    end

    def ensure_capture_paths!
      snapshot_sha256(snapshot_path)
      public_key(owner_public_key_path)
      if paths_overlap?(snapshot_path, output_root)
        raise Error, "snapshot and output paths must not overlap"
      end
      output_parent({"id" => "probe"})
      true
    end

    def output_parent(scene)
      current = File.dirname(path)
      (Pathname.new(document.fetch("output_dir")).each_filename.to_a + [scene.fetch("id")]).each do |part|
        current = File.join(current, part)
        raise Error, "output path contains a symlink: #{current}" if File.symlink?(current)
        raise Error, "output path component is not a directory: #{current}" if File.exist?(current) && !File.directory?(current)
      end
      current
    end

    def artifact_paths(scene, take_path)
      id = scene.fetch("id")
      {
        "cast" => File.join(take_path, "#{id}.cast"),
        "gif" => File.join(take_path, "#{id}.gif"),
        "log" => File.join(take_path, "capture.log"),
        "mp4" => File.join(take_path, "#{id}.mp4")
      }
    end

    def relative_artifact_paths(scene, take_name)
      artifact_paths(scene, File.join(document.fetch("output_dir"), scene.fetch("id"), take_name))
    end

    private

    def validate!
      expect_hash(document, "manifest")
      exact_keys(document, ROOT_KEYS, "manifest")
      raise Error, "schema must be #{MEDIA_SCHEMA}" unless document["schema"] == MEDIA_SCHEMA
      validate_id(document["project"], "project")
      validate_relative(document["output_dir"], "output_dir")

      capture_value = document["capture"]
      expect_hash(capture_value, "capture")
      exact_keys(capture_value, CAPTURE_KEYS, "capture")
      unless capture_value["image"].is_a?(String) && IMAGE_PATTERN.match?(capture_value["image"])
        raise Error, "capture.image must be pinned by sha256 digest"
      end
      validate_relative(capture_value["snapshot"], "capture.snapshot")
      validate_relative(capture_value["owner_public_key"], "capture.owner_public_key")
      raise Error, "capture.network must be none, bridge, or host" unless %w[none bridge host].include?(capture_value["network"])
      validate_integer(capture_value["timeout_seconds"], "capture.timeout_seconds", 1..3600)
      environment = capture_value["environment"]
      raise Error, "capture.environment must be an array" unless environment.is_a?(Array)
      unless environment == environment.sort.uniq && (environment - OPTIONAL_INPUTS).empty?
        raise Error, "capture.environment must be a sorted unique subset of #{OPTIONAL_INPUTS.join(", ")}"
      end

      scene_values = document["scenes"]
      raise Error, "scenes must be a non-empty array" unless scene_values.is_a?(Array) && !scene_values.empty?
      ids = scene_values.map.with_index do |scene, index|
        label = "scenes[#{index}]"
        expect_hash(scene, label)
        exact_keys(scene, SCENE_KEYS, label)
        validate_id(scene["id"], "#{label}.id")
        validate_nonempty_string(scene["title"], "#{label}.title")
        validate_integer(scene["duration_seconds"], "#{label}.duration_seconds", 1..3600)
        validate_integer(scene["columns"], "#{label}.columns", 20..500)
        validate_integer(scene["rows"], "#{label}.rows", 5..200)
        command = scene["command"]
        unless command.is_a?(Array) && command.length.between?(1, 64) &&
               command.all? { |item| item.is_a?(String) && !item.empty? && !item.include?("\0") }
          raise Error, "#{label}.command must be an argv array of 1 to 64 non-empty strings"
        end
        scene["id"]
      end
      raise Error, "scene ids must be unique" unless ids.uniq.length == ids.length
    end

    def exact_keys(value, expected, label)
      actual = value.keys.sort
      raise Error, "#{label} keys must be exactly #{expected.join(", ")}; got #{actual.join(", ")}" unless actual == expected
    end

    def expect_hash(value, label)
      raise Error, "#{label} must be an object" unless value.is_a?(Hash)
    end

    def validate_id(value, label)
      raise Error, "#{label} must be a portable lowercase id" unless value.is_a?(String) && ID_PATTERN.match?(value)
    end

    def validate_nonempty_string(value, label)
      raise Error, "#{label} must be non-empty text" unless value.is_a?(String) && !value.strip.empty?
    end

    def validate_integer(value, label, range)
      raise Error, "#{label} must be between #{range.begin} and #{range.end}" unless value.is_a?(Integer) && range.cover?(value)
    end

    def validate_relative(value, label)
      unless value.is_a?(String) && !value.empty? && !value.include?("\0") && !value.include?("\\")
        raise Error, "#{label} must be a normalized relative path"
      end
      pathname = Pathname.new(value)
      components = pathname.each_filename.to_a
      if pathname.absolute? || pathname.cleanpath.to_s != value || components.any? { |part| part == ".." } || value.include?("//")
        raise Error, "#{label} must be a normalized relative path"
      end
    end

    def resolve_relative(value)
      File.expand_path(value, File.dirname(path))
    end
  end

  class CLI
    include HiveVideoProduction

    def self.run(arguments, allowed_commands: nil)
      new(arguments, allowed_commands: allowed_commands).run
    rescue InterruptedCapture => error
      warn error.message
      130
    rescue Error, OptionParser::ParseError => error
      warn error.message
      1
    end

    def initialize(arguments, allowed_commands: nil)
      @arguments = arguments.dup
      @allowed_commands = allowed_commands
    end

    def run
      return help if @arguments.empty? || %w[-h --help help].include?(@arguments.first)

      command = @arguments.shift
      if @allowed_commands && !@allowed_commands.include?(command)
        raise Error, "command is not available through this stage entrypoint: #{command}"
      end
      case command
      when "validate" then validate
      when "dry-run" then dry_run
      when "approval-template" then approval_template
      when "capture" then capture
      when "verify" then verify
      when "publish-ready" then publish_ready
      else raise Error, "unknown command: #{command}; run --help"
      end
    end

    private

    def help
      puts <<~TEXT
        Video Production package commands:
          video-prepare.rb validate|dry-run
          video-approval-request.rb --stage capture|editorial  (approval-template)
          video-capture.rb                                    (capture)
          video-verify.rb                                     (verify)
          video-publish-ready.rb                              (publish-ready)

        Owner approval is a detached Ed25519 signature over the exact checked
        approval request. This package verifies receipts and never signs them.
      TEXT
      0
    end

    def parse_options(names, required: names)
      options = {}
      parser = OptionParser.new
      names.each do |name|
        flag = name.to_s.tr("_", "-")
        parser.on("--#{flag} VALUE") do |value|
          raise Error, "--#{flag} may be provided only once" if options.key?(name)
          options[name] = value
        end
      end
      parser.parse!(@arguments)
      raise Error, "unexpected arguments: #{@arguments.join(" ")}" unless @arguments.empty?
      required.each { |name| raise Error, "--#{name.to_s.tr("_", "-")} is required" unless options[name] }
      options
    end

    def validate
      options = parse_options([:manifest])
      manifest = MediaManifest.new(options.fetch(:manifest))
      emit(
        "schema" => "hive-video-production-validation/v1", "status" => "valid",
        "workflow" => WORKFLOW_ID, "project" => manifest.project,
        "manifest_sha256" => manifest.manifest_sha256, "tool_sha256" => tool_sha256,
        "scenes" => manifest.scenes.map { |scene| scene.fetch("id") }.sort
      )
    end

    def dry_run
      options = parse_options(%i[manifest scene])
      manifest = MediaManifest.new(options.fetch(:manifest))
      scene = manifest.scene(options.fetch(:scene))
      manifest.ensure_capture_paths!
      take = next_take(manifest, scene)
      _key, key_digest = public_key(manifest.owner_public_key_path)
      emit(
        "schema" => "hive-video-production-dry-run/v1", "status" => "ready",
        "workflow" => WORKFLOW_ID, "project" => manifest.project, "scene" => scene.fetch("id"),
        "take" => take, "image" => manifest.capture.fetch("image"),
        "snapshot_sha256" => snapshot_sha256(manifest.snapshot_path),
        "owner_public_key_sha256" => key_digest,
        "manifest_sha256" => manifest.manifest_sha256, "tool_sha256" => tool_sha256,
        "command_sha256" => command_sha256(scene), "host_prerequisites" => HOST_DEPENDENCIES,
        "artifacts" => manifest.relative_artifact_paths(scene, take)
      )
    end

    def approval_template
      options = parse_options(%i[manifest scene stage output verification], required: %i[manifest scene stage output])
      stage_name = options.fetch(:stage)
      raise Error, "--stage must be capture or editorial" unless %w[capture editorial].include?(stage_name)
      raise Error, "--verification is required for editorial approval" if stage_name == "editorial" && !options[:verification]
      raise Error, "--verification is valid only for editorial approval" if stage_name == "capture" && options[:verification]

      manifest = MediaManifest.new(options.fetch(:manifest))
      scene = manifest.scene(options.fetch(:scene))
      output = File.expand_path(options.fetch(:output))
      raise Error, "approval output already exists: #{output}" if File.exist?(output)
      context = stage_name == "capture" ? build_capture_request(manifest, scene, output) :
                                         build_editorial_request(manifest, scene, options.fetch(:verification))
      context["fingerprint"] = approval_fingerprint(context)
      sentence = owner_sentence(stage_name, checked: false)
      markdown = approval_markdown(context, sentence)
      atomic_write(output, markdown, overwrite: false)
      waiting = File.join(File.dirname(output), "WAITING")
      atomic_write(waiting, json(
        "schema" => "hive-video-production-waiting/v1", "status" => "waiting",
        "stage" => stage_name, "workflow" => WORKFLOW_ID, "scene" => scene.fetch("id"),
        "fingerprint" => context.fetch("fingerprint"), "approval" => output
      ))
      if stage_name == "capture"
        reservation = {
          "schema" => "hive-video-production-reservation/v1", "status" => "reserved",
          "workflow" => WORKFLOW_ID, "scene" => scene.fetch("id"),
          "take" => context.fetch("take"), "take_path" => context.fetch("take_path"),
          "approval" => output, "fingerprint" => context.fetch("fingerprint"),
          "staged_snapshot_path" => context.fetch("staged_snapshot_path"),
          "snapshot_sha256" => context.fetch("snapshot_sha256")
        }
        atomic_write(File.join(context.fetch("take_path"), "reservation.json"), json(reservation))
      end
      emit(
        "schema" => "hive-video-production-approval-request/v1", "status" => "waiting",
        "stage" => stage_name, "approval" => output, "waiting" => waiting,
        "fingerprint" => context.fetch("fingerprint"),
        "take_path" => context["take_path"], "staged_snapshot_path" => context["staged_snapshot_path"]
      )
    end

    def capture
      options = parse_options(%i[manifest scene approval receipt])
      manifest = MediaManifest.new(options.fetch(:manifest))
      scene = manifest.scene(options.fetch(:scene))
      context = validate_owner_approval!(
        options.fetch(:approval), options.fetch(:receipt), manifest, scene, stage: "capture"
      )
      take_path = context.fetch("take_path")
      active_step = "capture-preflight"
      container_cleanup = {"status" => "not-created", "retry_allowed" => true}
      artifacts = manifest.artifact_paths(scene, take_path)
      cidfile = File.join(take_path, "capture.cid")
      begin
        missing = HOST_DEPENDENCIES.reject { |name| executable_path(name) }
        raise Error, "missing host dependencies: #{missing.join(", ")}" unless missing.empty?
        validate_reservation!(take_path, context, options.fetch(:approval))

        active_step = "capture-initialize"
        approval_copy = File.join(take_path, "capture-owner-approval.md")
        receipt_copy = File.join(take_path, "capture-owner-approval.sig")
        FileUtils.cp(options.fetch(:approval), approval_copy, preserve: true)
        FileUtils.cp(options.fetch(:receipt), receipt_copy, preserve: true)
        capture_context = {
          "schema" => "hive-video-production-capture-context/v1", "status" => "running",
          "workflow" => WORKFLOW_ID, "project" => manifest.project, "scene" => scene.fetch("id"),
          "take" => context.fetch("take"), "take_path" => take_path,
          "manifest_sha256" => manifest.manifest_sha256, "tool_sha256" => tool_sha256,
          "command_sha256" => command_sha256(scene), "image" => manifest.capture.fetch("image"),
          "staged_snapshot_path" => context.fetch("staged_snapshot_path"),
          "snapshot_sha256" => context.fetch("snapshot_sha256"),
          "owner_public_key_sha256" => context.fetch("owner_public_key_sha256"),
          "approval_fingerprint" => context.fetch("fingerprint"),
          "approval_sha256" => sha256(approval_copy), "owner_receipt_sha256" => sha256(receipt_copy),
          "approval_path" => approval_copy, "owner_receipt_path" => receipt_copy,
          "artifacts" => artifacts, "cidfile" => cidfile
        }
        atomic_write(File.join(take_path, "capture-context.json"), json(capture_context))
        File.open(artifacts.fetch("log"), "ab") { |file| file.puts("workflow=#{WORKFLOW_ID} scene=#{scene.fetch("id")}") }

        active_step = "docker-image-inspect"
        inspect_result = run_logged(
          active_step, ["docker", "image", "inspect", manifest.capture.fetch("image")],
          manifest.capture.fetch("timeout_seconds"), artifacts.fetch("log")
        )
        raise_step!(active_step, inspect_result, "docker image inspection failed")

        docker_arguments = [
          "docker", "run", "--rm", "--pull=never", "--cidfile", cidfile,
          "--network", manifest.capture.fetch("network"),
          "--volume", "#{context.fetch("staged_snapshot_path")}:/workspace:ro",
          "--volume", "#{take_path}:/capture", "--workdir", "/workspace"
        ]
        manifest.capture.fetch("environment").each do |name|
          docker_arguments.concat(["--env", name]) if ENV.key?(name)
        end
        docker_arguments << manifest.capture.fetch("image")
        docker_arguments.concat(scene.fetch("command"))

        active_step = "asciinema"
        result = run_logged(
          active_step,
          [
            "asciinema", "rec", "--overwrite", "--cols", scene.fetch("columns").to_s,
            "--rows", scene.fetch("rows").to_s, "--command", Shellwords.join(docker_arguments),
            artifacts.fetch("cast")
          ],
          manifest.capture.fetch("timeout_seconds"), artifacts.fetch("log")
        )
        container_cleanup = cleanup_container(cidfile)
        raise_step!(active_step, result, "asciinema failed")
        raise Error, "container cleanup incomplete; retry is blocked" unless container_cleanup.fetch("status") == "complete"

        active_step = "agg"
        result = run_logged(active_step, ["agg", artifacts.fetch("cast"), artifacts.fetch("gif")],
                            manifest.capture.fetch("timeout_seconds"), artifacts.fetch("log"))
        raise_step!(active_step, result, "agg failed")

        active_step = "ffmpeg"
        result = run_logged(
          active_step,
          [
            "ffmpeg", "-y", "-i", artifacts.fetch("gif"), "-vf",
            "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p", "-c:v", "libx264",
            "-pix_fmt", "yuv420p", artifacts.fetch("mp4")
          ],
          manifest.capture.fetch("timeout_seconds"), artifacts.fetch("log")
        )
        raise_step!(active_step, result, "ffmpeg failed")

        capture_context["status"] = "captured"
        capture_context["container_cleanup"] = container_cleanup
        context_path = File.join(take_path, "capture-context.json")
        atomic_write(context_path, json(capture_context))
        capture_receipt = {
          "schema" => "hive-video-production-capture-receipt/v1", "status" => "captured",
          "workflow" => WORKFLOW_ID, "project" => manifest.project, "scene" => scene.fetch("id"),
          "take" => context.fetch("take"), "take_path" => take_path,
          "capture_context_sha256" => sha256(context_path),
          "approval_fingerprint" => context.fetch("fingerprint"),
          "owner_receipt_sha256" => sha256(receipt_copy),
          "snapshot_sha256" => context.fetch("snapshot_sha256"), "artifacts" => artifacts
        }
        receipt_path = File.join(take_path, "capture-receipt.json")
        atomic_write(receipt_path, json(capture_receipt))
        FileUtils.rm_f(File.join(File.dirname(File.expand_path(options.fetch(:approval))), "WAITING"))
        emit(
          "schema" => "hive-video-production-capture/v1", "status" => "captured",
          "workflow" => WORKFLOW_ID, "scene" => scene.fetch("id"), "take_path" => take_path,
          "artifacts" => artifacts, "capture_context_sha256" => sha256(context_path),
          "capture_receipt_sha256" => sha256(receipt_path),
          "approval_fingerprint" => context.fetch("fingerprint")
        )
      rescue Interrupt => error
        container_cleanup = cleanup_container(cidfile) unless container_cleanup.fetch("status") == "complete"
        interrupted = InterruptedCapture.new("#{active_step} interrupted: #{error.class}")
        record_failure(take_path, active_step, error: interrupted, interrupted: true, cleanup: container_cleanup)
        raise interrupted
      rescue InterruptedCapture => error
        container_cleanup = cleanup_container(cidfile) unless container_cleanup.fetch("status") == "complete"
        record_failure(take_path, active_step, error: error, interrupted: true, cleanup: container_cleanup)
        raise
      rescue StandardError => error
        container_cleanup = cleanup_container(cidfile) if File.exist?(cidfile) && container_cleanup.fetch("status") != "complete"
        record_failure(take_path, active_step, error: error, cleanup: container_cleanup)
        raise(error.is_a?(Error) ? error : Error.new("#{active_step} failed: #{error.class}: #{error.message}"))
      end
    end

    def verify
      options = parse_options(%i[manifest scene take])
      manifest = MediaManifest.new(options.fetch(:manifest))
      scene = manifest.scene(options.fetch(:scene))
      take_path = validate_take_path!(manifest, scene, options.fetch(:take))
      artifacts = manifest.artifact_paths(scene, take_path)
      capture_context, capture_receipt, errors = inspect_capture_evidence(manifest, scene, take_path, artifacts)
      hashes = {}
      artifacts.each do |kind, path|
        if !File.exist?(path)
          errors << "missing artifact: #{kind}"
        elsif File.symlink?(path)
          errors << "artifact must not be a symlink: #{kind}"
        elsif !File.file?(path) || File.size(path).zero?
          errors << "empty artifact: #{kind}"
        else
          hashes[kind] = sha256(path)
        end
      end

      mp4 = inspect_mp4(manifest, artifacts.fetch("mp4"), errors)
      result = {
        "schema" => "hive-video-production-verification/v1",
        "status" => errors.empty? ? "verified" : "invalid", "workflow" => WORKFLOW_ID,
        "project" => manifest.project, "scene" => scene.fetch("id"), "take" => File.basename(take_path),
        "manifest_sha256" => manifest.manifest_sha256, "tool_sha256" => tool_sha256,
        "capture_context_sha256" => capture_context && sha256(File.join(take_path, "capture-context.json")),
        "capture_receipt_sha256" => capture_receipt && sha256(File.join(take_path, "capture-receipt.json")),
        "approval_fingerprint" => capture_context && capture_context["approval_fingerprint"],
        "owner_receipt_sha256" => capture_context && capture_context["owner_receipt_sha256"],
        "snapshot_sha256" => capture_context && capture_context["snapshot_sha256"],
        "artifacts" => artifacts, "hashes" => hashes, "mp4" => mp4, "errors" => errors
      }
      atomic_write(File.join(take_path, "hashes.json"), json(
        "schema" => "hive-video-production-hashes/v1", "workflow" => WORKFLOW_ID,
        "scene" => scene.fetch("id"), "manifest_sha256" => manifest.manifest_sha256,
        "tool_sha256" => tool_sha256, "hashes" => hashes
      ))
      atomic_write(File.join(take_path, "verification.json"), json(result))
      puts json(result)
      errors.empty? ? 0 : 1
    end

    def publish_ready
      options = parse_options(%i[manifest scene take verification approval receipt])
      manifest = MediaManifest.new(options.fetch(:manifest))
      scene = manifest.scene(options.fetch(:scene))
      take_path = validate_take_path!(manifest, scene, options.fetch(:take))
      verification_path = File.expand_path(options.fetch(:verification))
      raise Error, "verification must be the selected take verification.json" unless verification_path == File.join(take_path, "verification.json")

      context = validate_owner_approval!(
        options.fetch(:approval), options.fetch(:receipt), manifest, scene,
        stage: "editorial", verification_path: verification_path
      )
      verification = load_verified_evidence!(verification_path, manifest, scene)
      result = {
        "schema" => "hive-video-production-publish-ready/v1", "status" => "publish-ready",
        "published" => false, "workflow" => WORKFLOW_ID, "project" => manifest.project,
        "scene" => scene.fetch("id"), "take" => File.basename(take_path),
        "manifest_sha256" => manifest.manifest_sha256, "tool_sha256" => tool_sha256,
        "verification_sha256" => sha256(verification_path),
        "capture_context_sha256" => verification.fetch("capture_context_sha256"),
        "capture_receipt_sha256" => verification.fetch("capture_receipt_sha256"),
        "capture_approval_fingerprint" => verification.fetch("approval_fingerprint"),
        "editorial_approval_fingerprint" => context.fetch("fingerprint"),
        "editorial_owner_receipt_sha256" => sha256(options.fetch(:receipt)),
        "snapshot_sha256" => verification.fetch("snapshot_sha256"),
        "artifacts" => verification.fetch("artifacts"), "hashes" => verification.fetch("hashes")
      }
      atomic_write(File.join(take_path, "publish-ready.json"), json(result))
      FileUtils.rm_f(File.join(File.dirname(File.expand_path(options.fetch(:approval))), "WAITING"))
      emit(result)
    end

    def emit(value)
      puts json(value)
      0
    end

    def command_sha256(scene)
      Digest::SHA256.hexdigest(JSON.generate(scene.fetch("command")))
    end

    def next_take(manifest, scene)
      parent = manifest.output_parent(scene)
      number = 1
      number += 1 while File.exist?(File.join(parent, format("take-%04d", number)))
      raise Error, "take allocation exhausted" if number > 9999
      format("take-%04d", number)
    end

    def allocate_take(manifest, scene)
      parent = manifest.output_parent(scene)
      FileUtils.mkdir_p(parent, mode: 0o700)
      1.upto(9999) do |number|
        path = File.join(parent, format("take-%04d", number))
        begin
          Dir.mkdir(path, 0o700)
          return path
        rescue Errno::EEXIST
          next
        end
      end
      raise Error, "take allocation exhausted"
    end

    def base_approval_context(manifest, scene, stage)
      _key, key_digest = public_key(manifest.owner_public_key_path)
      {
        "schema" => "hive-video-production-owner-request/v1", "stage" => stage,
        "workflow" => WORKFLOW_ID, "project" => manifest.project, "scene" => scene.fetch("id"),
        "manifest_sha256" => manifest.manifest_sha256, "tool_sha256" => tool_sha256,
        "command_sha256" => command_sha256(scene), "owner_public_key_sha256" => key_digest
      }
    end

    def build_capture_request(manifest, scene, output)
      manifest.ensure_capture_paths!
      take_path = allocate_take(manifest, scene)
      staged_path = "#{output}.snapshot"
      snapshot_digest = stage_snapshot(manifest.snapshot_path, staged_path)
      context = base_approval_context(manifest, scene, "capture")
      context.merge!(
        "image" => manifest.capture.fetch("image"), "network" => manifest.capture.fetch("network"),
        "snapshot_sha256" => snapshot_digest, "staged_snapshot_path" => staged_path,
        "take" => File.basename(take_path), "take_path" => take_path,
        "artifacts" => manifest.artifact_paths(scene, take_path)
      )
      context
    rescue StandardError
      FileUtils.rm_rf(take_path) if take_path && File.directory?(take_path) && Dir.empty?(take_path)
      raise
    end

    def build_editorial_request(manifest, scene, verification_path)
      verification = load_verified_evidence!(verification_path, manifest, scene)
      base_approval_context(manifest, scene, "editorial").merge(
        "verification_sha256" => sha256(verification_path),
        "capture_context_sha256" => verification.fetch("capture_context_sha256"),
        "capture_receipt_sha256" => verification.fetch("capture_receipt_sha256"),
        "capture_approval_fingerprint" => verification.fetch("approval_fingerprint"),
        "snapshot_sha256" => verification.fetch("snapshot_sha256"),
        "take" => verification.fetch("take"), "artifacts" => verification.fetch("artifacts"),
        "artifact_hashes" => verification.fetch("hashes")
      )
    end

    def approval_fingerprint(context)
      "sha256:#{Digest::SHA256.hexdigest(compact_json(context.reject { |key, _| key == "fingerprint" }))}"
    end

    def owner_sentence(stage_name, checked:)
      "- [#{checked ? "x" : " "}] I approve this exact #{stage_name} request as the repository owner."
    end

    def approval_display_value(value)
      return compact_json(value) unless value.is_a?(String)
      return JSON.generate(value) if value.match?(/[\0\r\n]/)

      value
    end

    def approval_markdown(context, sentence)
      unknown = context.keys - APPROVAL_FIELD_LABELS.keys
      raise Error, "owner request contains undisclosed fields: #{unknown.sort.join(", ")}" unless unknown.empty?

      lines = [
        "# Video production #{context.fetch("stage")} owner request", "", sentence, ""
      ]
      APPROVAL_FIELD_LABELS.each do |field, label|
        lines << "#{label}: #{approval_display_value(context.fetch(field))}" if context.key?(field)
      end
      lines.concat([
        "Context-JSON: #{Base64.strict_encode64(compact_json(context))}", "",
        "The package verifies a detached Ed25519 signature over this exact canonical request.", ""
      ])
      lines.join("\n")
    end

    def parse_approval_context(contents)
      values = contents.lines.filter_map do |line|
        match = /\AContext-JSON:\s*(\S+)\s*\z/.match(line)
        match[1] if match
      end
      raise Error, "approval context is missing or duplicated" unless values.length == 1
      JSON.parse(Base64.strict_decode64(values.first))
    rescue JSON::ParserError, ArgumentError => error
      raise Error, "approval context is invalid: #{error.message}"
    end

    def validate_owner_approval!(approval_path, receipt_path, manifest, scene, stage:, verification_path: nil)
      approval = File.expand_path(approval_path)
      receipt = File.expand_path(receipt_path)
      raise Error, "approval file must be a non-symlink regular file" unless File.file?(approval) && !File.symlink?(approval)
      raise Error, "owner receipt must be a non-symlink regular file" unless File.file?(receipt) && !File.symlink?(receipt)
      signature = File.binread(receipt)
      raise Error, "owner receipt is empty or too large" unless signature.bytesize.between?(1, 4096)

      contents = File.binread(approval)
      key, _digest = public_key(manifest.owner_public_key_path)
      raise Error, "owner receipt signature does not match approval bytes" unless key.verify(nil, signature, contents)

      checked = owner_sentence(stage, checked: true)
      raise Error, "exact #{stage} owner approval sentence is not checked" unless contents.lines(chomp: true).count(checked) == 1
      checked_boxes = contents.lines.grep(/\A\s*[-*+]\s+\[[xX]\]/)
      raise Error, "approval contains unrelated or duplicate checked boxes" unless checked_boxes.length == 1
      context = parse_approval_context(contents)
      expected = stage == "capture" ? expected_capture_context(manifest, scene, context) :
                                      build_editorial_request(manifest, scene, verification_path)
      expected["fingerprint"] = approval_fingerprint(expected)
      raise Error, "approval fingerprint does not match current context" unless context == expected
      canonical_request = approval_markdown(expected, owner_sentence(stage, checked: true))
      raise Error, "approval is not the exact canonical owner request" unless contents == canonical_request
      context
    rescue OpenSSL::PKey::PKeyError => error
      raise Error, "owner receipt signature is invalid: #{error.message}"
    end

    def expected_capture_context(manifest, scene, supplied)
      public_key(manifest.owner_public_key_path)
      raise Error, "snapshot and output paths must not overlap" if paths_overlap?(manifest.snapshot_path, manifest.output_root)
      manifest.output_parent(scene)
      staged = supplied.fetch("staged_snapshot_path")
      raise Error, "staged snapshot hash does not match owner request" unless snapshot_sha256(staged) == supplied.fetch("snapshot_sha256")
      take_path = validate_take_path!(manifest, scene, supplied.fetch("take_path"))
      expected = base_approval_context(manifest, scene, "capture").merge(
        "image" => manifest.capture.fetch("image"), "network" => manifest.capture.fetch("network"),
        "snapshot_sha256" => supplied.fetch("snapshot_sha256"), "staged_snapshot_path" => staged,
        "take" => File.basename(take_path), "take_path" => take_path,
        "artifacts" => manifest.artifact_paths(scene, take_path)
      )
      expected
    end

    def validate_reservation!(take_path, context, approval_path)
      reservation_path = File.join(take_path, "reservation.json")
      raise Error, "capture reservation is missing" unless File.file?(reservation_path) && !File.symlink?(reservation_path)
      reservation = JSON.parse(File.binread(reservation_path))
      expected = {
        "schema" => "hive-video-production-reservation/v1", "status" => "reserved",
        "workflow" => WORKFLOW_ID, "scene" => context.fetch("scene"), "take" => context.fetch("take"),
        "take_path" => take_path, "approval" => File.expand_path(approval_path),
        "fingerprint" => context.fetch("fingerprint"),
        "staged_snapshot_path" => context.fetch("staged_snapshot_path"),
        "snapshot_sha256" => context.fetch("snapshot_sha256")
      }
      raise Error, "capture reservation does not match owner request" unless reservation == expected
      extras = Dir.children(take_path) - ["reservation.json"]
      raise Error, "reserved take is not empty: #{extras.sort.join(", ")}" unless extras.empty?
    rescue JSON::ParserError => error
      raise Error, "capture reservation is invalid: #{error.message}"
    end

    def validate_take_path!(manifest, scene, path)
      expanded = File.expand_path(path)
      expected_parent = manifest.output_parent(scene)
      unless File.dirname(expanded) == expected_parent && TAKE_PATTERN.match?(File.basename(expanded)) && File.directory?(expanded)
        raise Error, "take must be an existing take-NNNN directory for scene #{scene.fetch("id")}"
      end
      raise Error, "take directory must not be a symlink" if File.symlink?(expanded)
      expanded
    end

    def run_logged(step, arguments, timeout_seconds, log_path)
      File.open(log_path, "ab") { |file| file.puts("step=#{step} command=#{Shellwords.join(arguments)}") }
      result = process_capture(arguments, timeout_seconds: timeout_seconds)
      File.open(log_path, "ab") do |file|
        file.write(result.fetch(:stdout))
        file.write(result.fetch(:stderr))
        file.puts(
          "step=#{step} timed_out=#{result.fetch(:timed_out)} interrupted=#{result.fetch(:interrupted)} " \
          "cleanup_incomplete=#{result.fetch(:cleanup_incomplete)} exit=#{result.fetch(:status)&.exitstatus || "missing"}"
        )
      end
      result.merge(success: !result.fetch(:timed_out) && !result.fetch(:interrupted) &&
                            !result.fetch(:cleanup_incomplete) && result.fetch(:status)&.success?)
    end

    def raise_step!(step, result, message)
      if result.fetch(:interrupted)
        error = InterruptedCapture.new("#{step} interrupted")
        error.define_singleton_method(:process_result) { result }
        raise error
      end
      return if result.fetch(:success)

      detail = result.fetch(:error) || result.fetch(:stderr).to_s.strip
      error = Error.new([message, detail].reject(&:empty?).join(": "))
      error.define_singleton_method(:process_result) { result }
      raise error
    end

    def cleanup_container(cidfile)
      return {"status" => "not-created", "retry_allowed" => true} unless File.file?(cidfile)
      cid = File.read(cidfile, encoding: "UTF-8").strip
      unless cid.match?(/\A[0-9a-f]{12,64}\z/)
        return {"status" => "incomplete", "retry_allowed" => false, "error" => "invalid cidfile"}
      end
      removal = process_capture(["docker", "rm", "-f", cid], timeout_seconds: CONTAINER_CLEANUP_SECONDS)
      inspection = process_capture(["docker", "inspect", cid], timeout_seconds: CONTAINER_CLEANUP_SECONDS)
      removal_conclusive = conclusive_process_result?(removal)
      inspection_conclusive = conclusive_process_result?(inspection)
      explicit_absence = inspection_conclusive && !inspection.fetch(:status).success? &&
                         no_such_container?(inspection.fetch(:stderr), cid)
      removal_succeeded = removal_conclusive && removal.fetch(:status).success?
      inspection_reports_present = inspection_conclusive && inspection.fetch(:status).success?
      unknown_inspection_failure = inspection_conclusive && !inspection.fetch(:status).success? && !explicit_absence
      complete = removal_conclusive && inspection_conclusive && !inspection_reports_present &&
                 !unknown_inspection_failure && (removal_succeeded || explicit_absence)
      {
        "status" => complete ? "complete" : "incomplete", "retry_allowed" => complete,
        "cid" => cid, "remove_exit_status" => removal.fetch(:status)&.exitstatus,
        "inspect_exit_status" => inspection.fetch(:status)&.exitstatus,
        "removal_succeeded" => removal_succeeded, "explicit_absence" => explicit_absence,
        "absent" => explicit_absence,
        "cleanup_incomplete" => !removal_conclusive || !inspection_conclusive,
        "error" => cleanup_error(removal, inspection, unknown_inspection_failure, inspection_reports_present)
      }
    rescue SystemCallError, IOError => error
      {"status" => "incomplete", "retry_allowed" => false, "error" => "#{error.class}: #{error.message}"}
    end

    def conclusive_process_result?(result)
      !result.fetch(:status).nil? && !result.fetch(:timed_out) && !result.fetch(:interrupted) &&
        !result.fetch(:cleanup_incomplete) && !result.fetch(:error)
    end

    def no_such_container?(stderr, cid)
      pattern = /\A\s*(?:Error(?: response from daemon)?:\s*)?No such (?:container|object):\s*#{Regexp.escape(cid)}\s*\z/i
      pattern.match?(stderr.to_s)
    end

    def cleanup_error(removal, inspection, unknown_inspection_failure, inspection_reports_present)
      return "container still exists after cleanup" if inspection_reports_present
      return "docker inspect failed without explicit no-such-container evidence" if unknown_inspection_failure
      return removal.fetch(:error) if removal.fetch(:error)
      return inspection.fetch(:error) if inspection.fetch(:error)
      return "docker rm timed out or cleanup was incomplete" unless conclusive_process_result?(removal)
      return "docker inspect timed out or cleanup was incomplete" unless conclusive_process_result?(inspection)

      nil
    end

    def record_failure(take_path, step, error: nil, interrupted: false, cleanup:)
      path = File.join(take_path, "failure.json")
      return if File.exist?(path)
      process_result = error.respond_to?(:process_result) ? error.process_result : nil
      retry_allowed = cleanup.fetch("retry_allowed", false) &&
                      !(process_result && process_result.fetch(:cleanup_incomplete))
      failure = {
        "schema" => "hive-video-production-failure/v1", "status" => "failed",
        "workflow" => WORKFLOW_ID, "step" => step, "take" => File.basename(take_path),
        "timed_out" => process_result ? process_result.fetch(:timed_out) : false,
        "interrupted" => interrupted || (process_result && process_result.fetch(:interrupted)),
        "process_cleanup_incomplete" => process_result ? process_result.fetch(:cleanup_incomplete) : false,
        "exit_status" => process_result&.fetch(:status)&.exitstatus,
        "error" => error && "#{error.class}: #{error.message}",
        "container_cleanup" => cleanup,
        "retry_allowed" => retry_allowed,
        "recovery" => retry_allowed ?
          "preserve this take, fix the declared prerequisite, and request a new owner-approved take" :
          "container or process cleanup is incomplete; owner intervention is required before retry"
      }
      atomic_write(path, json(failure), overwrite: false)
    rescue StandardError => record_error
      warn "could not persist failure evidence: #{record_error.class}: #{record_error.message}"
    end

    def inspect_capture_evidence(manifest, scene, take_path, artifacts)
      errors = []
      context_path = File.join(take_path, "capture-context.json")
      receipt_path = File.join(take_path, "capture-receipt.json")
      errors << "failed capture evidence is present" if File.exist?(File.join(take_path, "failure.json"))
      unless File.file?(context_path) && !File.symlink?(context_path)
        errors << "capture context is missing"
        return [nil, nil, errors]
      end
      unless File.file?(receipt_path) && !File.symlink?(receipt_path)
        errors << "capture receipt is missing"
        return [load_json(context_path, errors, "capture context"), nil, errors]
      end
      context = load_json(context_path, errors, "capture context")
      receipt = load_json(receipt_path, errors, "capture receipt")
      return [context, receipt, errors] unless context && receipt

      approval_path = File.join(take_path, "capture-owner-approval.md")
      owner_receipt_path = File.join(take_path, "capture-owner-approval.sig")
      expected_context = {
        "schema" => "hive-video-production-capture-context/v1", "status" => "captured",
        "workflow" => WORKFLOW_ID, "project" => manifest.project, "scene" => scene.fetch("id"),
        "take" => File.basename(take_path), "take_path" => take_path,
        "manifest_sha256" => manifest.manifest_sha256, "tool_sha256" => tool_sha256,
        "command_sha256" => command_sha256(scene), "image" => manifest.capture.fetch("image"),
        "staged_snapshot_path" => context["staged_snapshot_path"], "snapshot_sha256" => context["snapshot_sha256"],
        "owner_public_key_sha256" => context["owner_public_key_sha256"],
        "approval_fingerprint" => context["approval_fingerprint"],
        "approval_sha256" => context["approval_sha256"], "owner_receipt_sha256" => context["owner_receipt_sha256"],
        "approval_path" => approval_path, "owner_receipt_path" => owner_receipt_path,
        "artifacts" => artifacts, "cidfile" => File.join(take_path, "capture.cid"),
        "container_cleanup" => context["container_cleanup"]
      }
      errors << "capture context does not match the selected take" unless context == expected_context
      errors << "capture context status must be captured" unless context["status"] == "captured"
      begin
        validate_owner_approval!(approval_path, owner_receipt_path, manifest, scene, stage: "capture")
      rescue Error, KeyError, TypeError, ArgumentError => error
        errors << "capture owner approval is invalid: #{error.message}"
      end
      begin
        errors << "staged snapshot hash does not match capture context" unless
          snapshot_sha256(context.fetch("staged_snapshot_path")) == context.fetch("snapshot_sha256")
      rescue Error => error
        errors << error.message
      end
      errors << "capture owner approval hash does not match" unless safe_hash(approval_path) == context["approval_sha256"]
      errors << "capture owner receipt hash does not match" unless safe_hash(owner_receipt_path) == context["owner_receipt_sha256"]
      expected_receipt = {
        "schema" => "hive-video-production-capture-receipt/v1", "status" => "captured",
        "workflow" => WORKFLOW_ID, "project" => manifest.project, "scene" => scene.fetch("id"),
        "take" => File.basename(take_path), "take_path" => take_path,
        "capture_context_sha256" => sha256(context_path),
        "approval_fingerprint" => context["approval_fingerprint"],
        "owner_receipt_sha256" => context["owner_receipt_sha256"],
        "snapshot_sha256" => context["snapshot_sha256"], "artifacts" => artifacts
      }
      errors << "capture receipt does not match capture context" unless receipt == expected_receipt
      [context, receipt, errors]
    end

    def safe_hash(path)
      File.file?(path.to_s) && !File.symlink?(path.to_s) ? sha256(path) : nil
    end

    def load_json(path, errors, label)
      JSON.parse(File.binread(path))
    rescue JSON::ParserError, SystemCallError => error
      errors << "#{label} is invalid: #{error.message}"
      nil
    end

    def inspect_mp4(manifest, path, errors)
      return nil unless File.file?(path) && !File.symlink?(path) && File.size(path).positive?
      ffprobe = executable_path("ffprobe")
      unless ffprobe
        errors << "missing host dependency: ffprobe"
        return nil
      end
      probe = process_capture(
        [
          ffprobe, "-v", "error", "-show_entries", "stream=codec_name,pix_fmt,width,height",
          "-show_entries", "format=duration", "-of", "json", path
        ], timeout_seconds: manifest.capture.fetch("timeout_seconds")
      )
      if probe.fetch(:timed_out) || probe.fetch(:cleanup_incomplete) || !probe.fetch(:status)&.success?
        errors << "MP4 is unplayable: ffprobe failed"
        return nil
      end
      begin
        parsed = JSON.parse(probe.fetch(:stdout))
        streams = parsed.fetch("streams")
        raise KeyError, "streams is empty" unless streams.is_a?(Array) && !streams.empty?
        stream = streams.fetch(0)
        duration = Float(parsed.fetch("format").fetch("duration"))
        width = Integer(stream.fetch("width"))
        height = Integer(stream.fetch("height"))
        codec = stream.fetch("codec_name")
        pixel_format = stream.fetch("pix_fmt")
        errors << "MP4 codec must be h264, got #{codec}" unless codec == "h264"
        errors << "MP4 pixel format must be yuv420p, got #{pixel_format}" unless pixel_format == "yuv420p"
        errors << "MP4 must have positive even dimensions, got #{width}x#{height}" unless width.positive? && height.positive? && width.even? && height.even?
        errors << "MP4 duration must be positive" unless duration.positive?
        {"codec" => codec, "pixel_format" => pixel_format, "width" => width,
         "height" => height, "duration_seconds" => duration}
      rescue JSON::ParserError, KeyError, IndexError, ArgumentError, TypeError
        errors << "MP4 is unplayable: invalid ffprobe output"
        nil
      end
    end

    def load_verified_evidence!(path, manifest, scene)
      expanded = File.expand_path(path)
      raise Error, "verification file does not exist: #{expanded}" unless File.file?(expanded) && !File.symlink?(expanded)
      verification = JSON.parse(File.binread(expanded))
      raise Error, "verification schema is unsupported" unless verification["schema"] == "hive-video-production-verification/v1"
      raise Error, "verification is not verified" unless verification["status"] == "verified"
      raise Error, "verification workflow does not match" unless verification["workflow"] == WORKFLOW_ID
      raise Error, "verification scene does not match" unless verification["scene"] == scene.fetch("id")
      unless verification["manifest_sha256"] == manifest.manifest_sha256 && verification["tool_sha256"] == tool_sha256
        raise Error, "verification identity does not match current manifest and tool"
      end
      hashes = verification["hashes"]
      raise Error, "verification hashes are missing" unless hashes.is_a?(Hash) && hashes.keys.sort == %w[cast gif log mp4]
      take_path = File.dirname(expanded)
      artifacts = manifest.artifact_paths(scene, take_path)
      raise Error, "verification artifact paths do not match the selected take" unless verification["artifacts"] == artifacts
      context, _receipt, errors = inspect_capture_evidence(manifest, scene, take_path, artifacts)
      raise Error, errors.join("; ") unless errors.empty?
      raise Error, "verification capture context hash does not match" unless verification["capture_context_sha256"] == sha256(File.join(take_path, "capture-context.json"))
      raise Error, "verification capture receipt hash does not match" unless verification["capture_receipt_sha256"] == sha256(File.join(take_path, "capture-receipt.json"))
      raise Error, "verification approval fingerprint does not match" unless verification["approval_fingerprint"] == context["approval_fingerprint"]
      raise Error, "verification owner receipt does not match" unless verification["owner_receipt_sha256"] == context["owner_receipt_sha256"]
      raise Error, "verification snapshot does not match" unless verification["snapshot_sha256"] == context["snapshot_sha256"]
      artifacts.each do |kind, artifact_path|
        unless !File.symlink?(artifact_path) && File.file?(artifact_path) && File.size(artifact_path).positive? &&
               hashes.fetch(kind) == sha256(artifact_path)
          raise Error, "artifact hash does not match verification: #{kind}"
        end
      end
      verification
    rescue JSON::ParserError => error
      raise Error, "verification is not valid JSON: #{error.message}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit HiveVideoProduction::CLI.run(ARGV)
end
