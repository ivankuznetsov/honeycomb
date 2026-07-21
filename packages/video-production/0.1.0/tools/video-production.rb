#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "shellwords"
require "timeout"

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

  class Error < StandardError; end

  module_function

  def canonical_json(value)
    case value
    when Hash
      value.keys.sort.to_h { |key| [key, canonical_json(value.fetch(key))] }
    when Array
      value.map { |item| canonical_json(item) }
    else
      value
    end
  end

  def json(value)
    JSON.pretty_generate(canonical_json(value)) + "\n"
  end

  def atomic_write(path, contents, mode: nil)
    directory = File.dirname(path)
    FileUtils.mkdir_p(directory)
    temporary = File.join(directory, ".#{File.basename(path)}.tmp-#{Process.pid}")
    File.open(temporary, "wb", mode || 0o644) do |file|
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

  def tool_sha256
    sha256(File.realpath(__FILE__))
  end

  def redact_runtime_values(value)
    OPTIONAL_INPUTS.filter_map { |name| ENV[name] }
                   .reject(&:empty?)
                   .uniq
                   .sort_by { |secret| -secret.bytesize }
                   .reduce(value.b.dup) { |text, secret| text.gsub(secret.b, "[REDACTED]") }
  end

  def executable_path(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |directory|
      next if directory.empty?

      candidate = File.join(directory, name)
      candidate if File.file?(candidate) && File.executable?(candidate)
    end.first
  end

  def snapshot_sha256(path)
    raise Error, "snapshot does not exist: #{path}" unless File.exist?(path)
    raise Error, "snapshot must not be a symlink: #{path}" if File.symlink?(path)

    digest = Digest::SHA256.new
    if File.file?(path)
      digest << "file\0#{File.basename(path)}\0"
      digest << File.binread(path)
    elsif File.directory?(path)
      entries = Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sort
      entries.reject! { |entry| %w[. ..].include?(File.basename(entry)) }
      entries.each do |entry|
        relative = Pathname.new(entry).relative_path_from(Pathname.new(path)).to_s
        raise Error, "snapshot contains a symlink: #{relative}" if File.symlink?(entry)
        next if File.directory?(entry)
        raise Error, "snapshot contains a non-regular file: #{relative}" unless File.file?(entry)

        digest << "file\0#{relative}\0#{File.stat(entry).mode & 0o111}\0"
        digest << File.binread(entry)
      end
    else
      raise Error, "snapshot is not a regular file or directory: #{path}"
    end
    digest.hexdigest
  end

  def process_capture(arguments, timeout_seconds:)
    stdout_data = +""
    stderr_data = +""
    status = nil
    timed_out = false

    Open3.popen3(*arguments, pgroup: true) do |stdin, stdout, stderr, wait_thread|
      stdin.close
      stdout_reader = Thread.new { stdout.read }
      stderr_reader = Thread.new { stderr.read }
      begin
        Timeout.timeout(timeout_seconds) { status = wait_thread.value }
      rescue Timeout::Error
        timed_out = true
        begin
          Process.kill("TERM", -wait_thread.pid)
        rescue Errno::ESRCH
          nil
        end
        begin
          Timeout.timeout(2) { status = wait_thread.value }
        rescue Timeout::Error
          begin
            Process.kill("KILL", -wait_thread.pid)
          rescue Errno::ESRCH
            nil
          end
          status = wait_thread.value
        end
      ensure
        stdout_data = stdout_reader.value
        stderr_data = stderr_reader.value
      end
    end

    {stdout: stdout_data, stderr: stderr_data, status: status, timed_out: timed_out}
  rescue Errno::ENOENT => error
    {stdout: "", stderr: error.message, status: nil, timed_out: false}
  end

  class MediaManifest
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
          @index += 1 # colon; JSON.parse has already validated syntax
          scan_value
          skip_space
          break @index += 1 if current == "}"

          @index += 1 # comma
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

          @index += 1 # comma
        end
      end

      def scan_string
        start = @index
        @index += 1
        loop do
          case current
          when "\\"
            @index += 2
          when '"'
            @index += 1
            return JSON.parse(@bytes.byteslice(start...@index))
          else
            @index += 1
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
        byte = @bytes.getbyte(@index)
        byte&.chr
      end
    end

    ROOT_KEYS = %w[capture output_dir project scenes schema].freeze
    CAPTURE_KEYS = %w[environment image network snapshot timeout_seconds].freeze
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

    def manifest_sha256
      Digest::SHA256.hexdigest(@bytes)
    end

    def project
      document.fetch("project")
    end

    def scenes
      document.fetch("scenes")
    end

    def scene(id)
      scenes.find { |item| item.fetch("id") == id } || raise(Error, "unknown scene: #{id}")
    end

    def capture
      document.fetch("capture")
    end

    def output_root
      resolve_relative(document.fetch("output_dir"))
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

    def snapshot_path
      resolve_relative(capture.fetch("snapshot"))
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
      base = File.join(document.fetch("output_dir"), scene.fetch("id"), take_name)
      artifact_paths(scene, base)
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
      return if actual == expected

      raise Error, "#{label} keys must be exactly #{expected.join(", ")}; got #{actual.join(", ")}"
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
      if pathname.absolute? || pathname.cleanpath.to_s != value || pathname.each_filename.any? { |part| part == ".." }
        raise Error, "#{label} must be a normalized relative path"
      end
    end

    def resolve_relative(value)
      File.expand_path(value, File.dirname(path))
    end
  end

  class CLI
    def self.run(arguments)
      new(arguments).run
    rescue Error, OptionParser::ParseError => error
      warn error.message
      1
    rescue Interrupt
      warn "interrupted"
      130
    end

    def initialize(arguments)
      @arguments = arguments.dup
    end

    def run
      return help if @arguments.empty? || %w[-h --help help].include?(@arguments.first)

      command = @arguments.shift
      case command
      when "validate" then validate
      when "dry-run" then dry_run
      when "approval-template" then approval_template
      when "capture" then capture
      when "verify" then verify
      when "publish-ready" then publish_ready
      else
        raise Error, "unknown command: #{command}; run --help"
      end
    end

    private

    def help
      puts <<~TEXT
        Usage: video-production.rb COMMAND [options]

        Commands:
          validate           Validate a project media manifest and emit JSON
          dry-run            Plan one scene without allocating a take or invoking host tools
          approval-template  Write a fingerprint-bound capture or editorial checklist
          capture            Run one checked, bounded trusted-owner capture
          verify             Inspect cast, GIF, log, and H.264/yuv420p MP4 evidence
          publish-ready      Validate editorial approval and write a local terminal record
      TEXT
      0
    end

    def options_for(*names)
      options = {}
      parser = OptionParser.new
      names.each do |name|
        flag = name.to_s.tr("_", "-")
        parser.on("--#{flag} VALUE") { |value| options[name] = value }
      end
      parser.parse!(@arguments)
      raise Error, "unexpected arguments: #{@arguments.join(" ")}" unless @arguments.empty?
      names.each { |name| raise Error, "--#{name.to_s.tr("_", "-")} is required" unless options[name] }
      options
    end

    def validate
      options = options_for(:manifest)
      manifest = MediaManifest.new(options.fetch(:manifest))
      emit(
        "schema" => "hive-video-production-validation/v1",
        "status" => "valid",
        "workflow" => WORKFLOW_ID,
        "project" => manifest.project,
        "manifest_sha256" => manifest.manifest_sha256,
        "tool_sha256" => HiveVideoProduction.tool_sha256,
        "scenes" => manifest.scenes.map { |scene| scene.fetch("id") }.sort
      )
    end

    def dry_run
      options = options_for(:manifest, :scene)
      manifest = MediaManifest.new(options.fetch(:manifest))
      scene = manifest.scene(options.fetch(:scene))
      snapshot_digest = HiveVideoProduction.snapshot_sha256(manifest.snapshot_path)
      take = next_take(manifest, scene)
      emit(
        "schema" => "hive-video-production-dry-run/v1",
        "status" => "ready",
        "workflow" => WORKFLOW_ID,
        "project" => manifest.project,
        "scene" => scene.fetch("id"),
        "take" => take,
        "image" => manifest.capture.fetch("image"),
        "snapshot_sha256" => snapshot_digest,
        "manifest_sha256" => manifest.manifest_sha256,
        "tool_sha256" => HiveVideoProduction.tool_sha256,
        "command_sha256" => command_sha256(scene),
        "host_prerequisites" => HOST_DEPENDENCIES,
        "artifacts" => manifest.relative_artifact_paths(scene, take)
      )
    end

    def approval_template
      required = %i[manifest scene stage output]
      required << :verification if @arguments.each_slice(2).any? { |pair| pair.first == "--stage" && pair.last == "editorial" }
      options = options_for(*required)
      raise Error, "--stage must be capture or editorial" unless %w[capture editorial].include?(options.fetch(:stage))

      manifest = MediaManifest.new(options.fetch(:manifest))
      scene = manifest.scene(options.fetch(:scene))
      context = approval_context(
        manifest, scene, stage: options.fetch(:stage), verification_path: options[:verification]
      )
      fingerprint = approval_fingerprint(context)
      output = File.expand_path(options.fetch(:output))
      checklist = <<~MARKDOWN
        # Video production #{options.fetch(:stage)} approval

        - [ ] I approve this exact #{options.fetch(:stage)} fingerprint as the trusted owner.

        Stage: #{options.fetch(:stage)}
        Workflow: #{WORKFLOW_ID}
        Scene: #{scene.fetch("id")}
        Fingerprint: #{fingerprint}
        Manifest-SHA256: #{manifest.manifest_sha256}
        Tool-SHA256: #{HiveVideoProduction.tool_sha256}

        Checking the box authorizes only the bounded operation represented by this fingerprint.
      MARKDOWN
      HiveVideoProduction.atomic_write(output, checklist)
      waiting = File.join(File.dirname(output), "WAITING")
      HiveVideoProduction.atomic_write(waiting, HiveVideoProduction.json(
        "schema" => "hive-video-production-waiting/v1",
        "status" => "waiting",
        "stage" => options.fetch(:stage),
        "workflow" => WORKFLOW_ID,
        "scene" => scene.fetch("id"),
        "fingerprint" => fingerprint
      ))
      emit(
        "schema" => "hive-video-production-approval-template/v1",
        "status" => "waiting",
        "stage" => options.fetch(:stage),
        "approval" => output,
        "waiting" => waiting,
        "fingerprint" => fingerprint
      )
    end

    def capture
      options = options_for(:manifest, :scene, :approval)
      manifest = MediaManifest.new(options.fetch(:manifest))
      scene = manifest.scene(options.fetch(:scene))
      context = approval_context(manifest, scene, stage: "capture")
      fingerprint = validate_approval!(options.fetch(:approval), context)
      missing = HOST_DEPENDENCIES.reject { |name| HiveVideoProduction.executable_path(name) }
      raise Error, "missing host dependencies: #{missing.join(", ")}" unless missing.empty?

      take_path = allocate_take(manifest, scene)
      artifacts = manifest.artifact_paths(scene, take_path)
      capture_context = {
        "schema" => "hive-video-production-capture-context/v1",
        "status" => "running",
        "workflow" => WORKFLOW_ID,
        "project" => manifest.project,
        "scene" => scene.fetch("id"),
        "take" => File.basename(take_path),
        "manifest_sha256" => manifest.manifest_sha256,
        "tool_sha256" => HiveVideoProduction.tool_sha256,
        "snapshot_sha256" => context.fetch("snapshot_sha256"),
        "command_sha256" => command_sha256(scene),
        "approval_fingerprint" => fingerprint,
        "artifacts" => artifacts
      }
      HiveVideoProduction.atomic_write(File.join(take_path, "capture-context.json"),
                                       HiveVideoProduction.json(capture_context))
      File.open(artifacts.fetch("log"), "ab") { |file| file.puts("workflow=#{WORKFLOW_ID} scene=#{scene.fetch("id")}") }

      inspect_result = run_logged(
        "docker-image-inspect",
        ["docker", "image", "inspect", manifest.capture.fetch("image")],
        manifest.capture.fetch("timeout_seconds"), artifacts.fetch("log")
      )
      fail_capture!(take_path, "docker-image-inspect", inspect_result,
                    "docker image inspection failed") unless inspect_result.fetch(:success)

      docker_arguments = [
        "docker", "run", "--rm", "--network", manifest.capture.fetch("network"),
        "--volume", "#{manifest.snapshot_path}:/workspace:ro",
        "--volume", "#{take_path}:/capture",
        "--workdir", "/workspace"
      ]
      manifest.capture.fetch("environment").each do |name|
        docker_arguments.concat(["--env", name]) if ENV.key?(name)
      end
      docker_arguments << manifest.capture.fetch("image")
      docker_arguments.concat(scene.fetch("command"))

      steps = [
        [
          "asciinema",
          [
            "asciinema", "rec", "--overwrite", "--cols", scene.fetch("columns").to_s,
            "--rows", scene.fetch("rows").to_s, "--command", Shellwords.join(docker_arguments),
            artifacts.fetch("cast")
          ]
        ],
        ["agg", ["agg", artifacts.fetch("cast"), artifacts.fetch("gif")]],
        [
          "ffmpeg",
          [
            "ffmpeg", "-y", "-i", artifacts.fetch("gif"), "-vf",
            "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", artifacts.fetch("mp4")
          ]
        ]
      ]
      steps.each do |step, arguments|
        result = run_logged(step, arguments, manifest.capture.fetch("timeout_seconds"), artifacts.fetch("log"))
        fail_capture!(take_path, step, result, "#{step} failed") unless result.fetch(:success)
      end

      capture_context["status"] = "captured"
      HiveVideoProduction.atomic_write(File.join(take_path, "capture-context.json"),
                                       HiveVideoProduction.json(capture_context))
      FileUtils.rm_f(File.join(File.dirname(File.expand_path(options.fetch(:approval))), "WAITING"))
      emit(
        "schema" => "hive-video-production-capture/v1",
        "status" => "captured",
        "workflow" => WORKFLOW_ID,
        "scene" => scene.fetch("id"),
        "take_path" => take_path,
        "artifacts" => artifacts,
        "manifest_sha256" => manifest.manifest_sha256,
        "tool_sha256" => HiveVideoProduction.tool_sha256,
        "approval_fingerprint" => fingerprint
      )
    end

    def verify
      options = options_for(:manifest, :scene, :take)
      manifest = MediaManifest.new(options.fetch(:manifest))
      scene = manifest.scene(options.fetch(:scene))
      take_path = validate_take_path!(manifest, scene, options.fetch(:take))
      artifacts = manifest.artifact_paths(scene, take_path)
      errors = []
      hashes = {}

      artifacts.each do |kind, path|
        if !File.exist?(path)
          errors << "missing artifact: #{kind}"
        elsif File.symlink?(path)
          errors << "artifact must not be a symlink: #{kind}"
        elsif !File.file?(path) || File.size(path).zero?
          errors << "empty artifact: #{kind}"
        else
          hashes[kind] = HiveVideoProduction.sha256(path)
        end
      end

      mp4 = nil
      if File.file?(artifacts.fetch("mp4")) && File.size(artifacts.fetch("mp4")).positive?
        ffprobe = HiveVideoProduction.executable_path("ffprobe")
        if ffprobe.nil?
          errors << "missing host dependency: ffprobe"
        else
          probe = HiveVideoProduction.process_capture(
            [
              ffprobe, "-v", "error", "-show_entries", "stream=codec_name,pix_fmt,width,height",
              "-show_entries", "format=duration", "-of", "json", artifacts.fetch("mp4")
            ],
            timeout_seconds: manifest.capture.fetch("timeout_seconds")
          )
          if probe.fetch(:timed_out) || !probe.fetch(:status)&.success?
            errors << "MP4 is unplayable: ffprobe failed"
          else
            begin
              parsed = JSON.parse(probe.fetch(:stdout))
              stream = parsed.fetch("streams").fetch(0)
              duration = Float(parsed.fetch("format").fetch("duration"))
              width = Integer(stream.fetch("width"))
              height = Integer(stream.fetch("height"))
              codec = stream.fetch("codec_name")
              pixel_format = stream.fetch("pix_fmt")
              errors << "MP4 codec must be h264, got #{codec}" unless codec == "h264"
              errors << "MP4 pixel format must be yuv420p, got #{pixel_format}" unless pixel_format == "yuv420p"
              errors << "MP4 must have positive even dimensions, got #{width}x#{height}" unless width.positive? && height.positive? && width.even? && height.even?
              errors << "MP4 duration must be positive" unless duration.positive?
              mp4 = {
                "codec" => codec,
                "pixel_format" => pixel_format,
                "width" => width,
                "height" => height,
                "duration_seconds" => duration
              }
            rescue JSON::ParserError, KeyError, ArgumentError, TypeError
              errors << "MP4 is unplayable: invalid ffprobe output"
            end
          end
        end
      end

      result = {
        "schema" => "hive-video-production-verification/v1",
        "status" => errors.empty? ? "verified" : "invalid",
        "workflow" => WORKFLOW_ID,
        "project" => manifest.project,
        "scene" => scene.fetch("id"),
        "take" => File.basename(take_path),
        "manifest_sha256" => manifest.manifest_sha256,
        "tool_sha256" => HiveVideoProduction.tool_sha256,
        "artifacts" => artifacts,
        "hashes" => hashes,
        "mp4" => mp4,
        "errors" => errors
      }
      HiveVideoProduction.atomic_write(File.join(take_path, "hashes.json"), HiveVideoProduction.json(
        "schema" => "hive-video-production-hashes/v1",
        "workflow" => WORKFLOW_ID,
        "scene" => scene.fetch("id"),
        "manifest_sha256" => manifest.manifest_sha256,
        "tool_sha256" => HiveVideoProduction.tool_sha256,
        "hashes" => hashes
      ))
      HiveVideoProduction.atomic_write(File.join(take_path, "verification.json"), HiveVideoProduction.json(result))
      puts HiveVideoProduction.json(result)
      errors.empty? ? 0 : 1
    end

    def publish_ready
      options = options_for(:manifest, :scene, :take, :verification, :approval)
      manifest = MediaManifest.new(options.fetch(:manifest))
      scene = manifest.scene(options.fetch(:scene))
      take_path = validate_take_path!(manifest, scene, options.fetch(:take))
      verification_path = File.expand_path(options.fetch(:verification))
      expected_verification = File.join(take_path, "verification.json")
      raise Error, "verification must be the selected take verification.json" unless verification_path == expected_verification

      context = approval_context(
        manifest, scene, stage: "editorial", verification_path: verification_path
      )
      fingerprint = validate_approval!(options.fetch(:approval), context)
      verification = load_verified_evidence!(verification_path, manifest, scene)
      result = {
        "schema" => "hive-video-production-publish-ready/v1",
        "status" => "publish-ready",
        "published" => false,
        "workflow" => WORKFLOW_ID,
        "project" => manifest.project,
        "scene" => scene.fetch("id"),
        "take" => File.basename(take_path),
        "manifest_sha256" => manifest.manifest_sha256,
        "tool_sha256" => HiveVideoProduction.tool_sha256,
        "verification_sha256" => HiveVideoProduction.sha256(verification_path),
        "approval_fingerprint" => fingerprint,
        "artifacts" => verification.fetch("artifacts"),
        "hashes" => verification.fetch("hashes")
      }
      HiveVideoProduction.atomic_write(File.join(take_path, "publish-ready.json"), HiveVideoProduction.json(result))
      FileUtils.rm_f(File.join(File.dirname(File.expand_path(options.fetch(:approval))), "WAITING"))
      emit(result)
    end

    def emit(value)
      puts HiveVideoProduction.json(value)
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
      FileUtils.mkdir_p(parent)
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

    def approval_context(manifest, scene, stage:, verification_path: nil)
      context = {
        "stage" => stage,
        "workflow" => WORKFLOW_ID,
        "project" => manifest.project,
        "scene" => scene.fetch("id"),
        "manifest_sha256" => manifest.manifest_sha256,
        "tool_sha256" => HiveVideoProduction.tool_sha256,
        "command_sha256" => command_sha256(scene)
      }
      if stage == "capture"
        context["image"] = manifest.capture.fetch("image")
        context["snapshot_sha256"] = HiveVideoProduction.snapshot_sha256(manifest.snapshot_path)
      else
        raise Error, "--verification is required for editorial approval" unless verification_path

        verification = load_verified_evidence!(verification_path, manifest, scene)
        context["verification_sha256"] = HiveVideoProduction.sha256(verification_path)
        context["artifact_hashes"] = verification.fetch("hashes")
      end
      context
    end

    def approval_fingerprint(context)
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(HiveVideoProduction.canonical_json(context)))}"
    end

    def validate_approval!(path, context)
      approval_path = File.expand_path(path)
      raise Error, "approval file does not exist: #{approval_path}" unless File.file?(approval_path)

      contents = File.read(approval_path, encoding: "UTF-8")
      raise Error, "approval checklist is not checked" unless contents.scan(/^- \[[xX]\]/).length == 1
      expected = {
        "Stage" => context.fetch("stage"),
        "Workflow" => WORKFLOW_ID,
        "Scene" => context.fetch("scene"),
        "Fingerprint" => approval_fingerprint(context),
        "Manifest-SHA256" => context.fetch("manifest_sha256"),
        "Tool-SHA256" => context.fetch("tool_sha256")
      }
      expected.each do |label, value|
        actual = contents.lines.filter_map do |line|
          match = /\A#{Regexp.escape(label)}:\s*(.*?)\s*\z/.match(line)
          match[1] if match
        end
        raise Error, "approval #{label.downcase} is missing or duplicated" unless actual.length == 1
        next if actual.first == value

        message = label == "Fingerprint" ? "approval fingerprint does not match" : "approval #{label.downcase} does not match"
        raise Error, message
      end
      expected.fetch("Fingerprint")
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

    def load_verified_evidence!(path, manifest, scene)
      expanded = File.expand_path(path)
      raise Error, "verification file does not exist: #{expanded}" unless File.file?(expanded)

      verification = JSON.parse(File.binread(expanded))
      raise Error, "verification is not verified" unless verification["status"] == "verified"
      raise Error, "verification workflow does not match" unless verification["workflow"] == WORKFLOW_ID
      raise Error, "verification scene does not match" unless verification["scene"] == scene.fetch("id")
      unless verification["manifest_sha256"] == manifest.manifest_sha256 &&
             verification["tool_sha256"] == HiveVideoProduction.tool_sha256
        raise Error, "verification identity does not match current manifest and tool"
      end
      raise Error, "verification hashes are missing" unless verification["hashes"].is_a?(Hash) &&
                                                                  verification["hashes"].keys.sort == %w[cast gif log mp4]

      expected_artifacts = manifest.artifact_paths(scene, File.dirname(expanded))
      raise Error, "verification artifact paths do not match the selected take" unless verification["artifacts"] == expected_artifacts
      expected_artifacts.each do |kind, artifact_path|
        unless !File.symlink?(artifact_path) && File.file?(artifact_path) && File.size(artifact_path).positive? &&
               verification.fetch("hashes").fetch(kind) == HiveVideoProduction.sha256(artifact_path)
          raise Error, "artifact hash does not match verification: #{kind}"
        end
      end

      verification
    rescue JSON::ParserError => error
      raise Error, "verification is not valid JSON: #{error.message}"
    end

    def run_logged(step, arguments, timeout_seconds, log_path)
      File.open(log_path, "ab") { |file| file.puts("step=#{step} command=#{Shellwords.join(arguments)}") }
      result = HiveVideoProduction.process_capture(arguments, timeout_seconds: timeout_seconds)
      File.open(log_path, "ab") do |file|
        file.write(HiveVideoProduction.redact_runtime_values(result.fetch(:stdout)))
        file.write(HiveVideoProduction.redact_runtime_values(result.fetch(:stderr)))
        file.puts("step=#{step} timed_out=#{result.fetch(:timed_out)} exit=#{result.fetch(:status)&.exitstatus || "missing"}")
      end
      result.merge(success: !result.fetch(:timed_out) && result.fetch(:status)&.success?)
    end

    def fail_capture!(take_path, step, result, message)
      failure = {
        "schema" => "hive-video-production-failure/v1",
        "status" => "failed",
        "workflow" => WORKFLOW_ID,
        "step" => step,
        "timed_out" => result.fetch(:timed_out),
        "exit_status" => result.fetch(:status)&.exitstatus,
        "take" => File.basename(take_path),
        "recovery" => "preserve this take as evidence, fix the declared prerequisite, and retry to allocate a new take"
      }
      HiveVideoProduction.atomic_write(File.join(take_path, "failure.json"), HiveVideoProduction.json(failure))
      raise Error, message
    end
  end
end

exit HiveVideoProduction::CLI.run(ARGV)
