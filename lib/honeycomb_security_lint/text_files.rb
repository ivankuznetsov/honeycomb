# frozen_string_literal: true

require "digest"
require "pathname"

module HoneycombSecurityLint
  class TextFiles
    Source = Struct.new(:path, :absolute_path, :bytes, :text, :sha256, keyword_init: true) do
      def evidence
        {"path" => path, "bytes" => bytes.bytesize, "sha256" => sha256, "kind" => text ? "text" : "binary"}
      end
    end
    Result = Struct.new(:files, :total_bytes, keyword_init: true)

    class Invalid < StandardError; end

    def initialize(root:, limits:)
      @root = File.realpath(root)
      @limits = limits
    rescue SystemCallError => e
      raise Invalid, "repository root is unreadable: #{e.class}"
    end

    def collect(version_root)
      validate_relative!(version_root)
      absolute_root = File.join(@root, version_root)
      root_stat = File.lstat(absolute_root)
      raise Invalid, "version root must be a real directory" unless root_stat.directory? && !root_stat.symlink?

      files = []
      total = 0
      walk(absolute_root, version_root) do |absolute, relative, stat|
        raise Invalid, "scan file count exceeds policy" if files.length >= @limits.fetch("max_files")
        raise Invalid, "#{relative} exceeds per-file scan limit" if stat.size > @limits.fetch("max_file_bytes")

        bytes = File.binread(absolute)
        after = File.lstat(absolute)
        unless after.file? && !after.symlink? && after.dev == stat.dev && after.ino == stat.ino && after.size == bytes.bytesize
          raise Invalid, "#{relative} changed while it was being read"
        end
        total += bytes.bytesize
        raise Invalid, "total scan bytes exceed policy" if total > @limits.fetch("max_total_bytes")

        text = decode_text(bytes, relative)
        files << Source.new(path: relative, absolute_path: absolute, bytes: bytes,
                            text: text, sha256: Digest::SHA256.hexdigest(bytes))
      end
      Result.new(files: files.sort_by(&:path), total_bytes: total)
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Invalid, "version content became unreadable: #{e.class}"
    end

    private

    def walk(directory, relative_directory, &block)
      Dir.children(directory).sort.each do |entry|
        validate_entry!(entry)
        absolute = File.join(directory, entry)
        relative = "#{relative_directory}/#{entry}"
        stat = File.lstat(absolute)
        if stat.symlink?
          raise Invalid, "#{relative} is a symlink"
        elsif stat.directory?
          walk(absolute, relative, &block)
        elsif stat.file?
          yield absolute, relative, stat
        else
          raise Invalid, "#{relative} is a special file"
        end
      end
    end

    def validate_relative!(path)
      invalid = path.to_s.empty? || path.to_s.start_with?("/") || path.to_s.include?("\\") ||
                path.to_s.match?(/[\x00-\x20\x7f]/) || Pathname.new(path.to_s).cleanpath.to_s != path.to_s
      resolved = File.expand_path(path.to_s, @root)
      invalid ||= !resolved.start_with?(@root + File::SEPARATOR)
      raise Invalid, "version root is not a safe repository-relative path" if invalid
    end

    def validate_entry!(entry)
      invalid = entry.empty? || entry == "." || entry == ".." || entry.include?("\\") ||
                entry.match?(/[\x00-\x1f\x7f]/) || entry != entry.strip
      raise Invalid, "unsafe or ambiguous content path" if invalid
    end

    def decode_text(bytes, path)
      return nil if bytes.include?("\0")

      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise Invalid, "#{path} is not valid UTF-8 text" unless text.valid_encoding?

      text
    end
  end
end
