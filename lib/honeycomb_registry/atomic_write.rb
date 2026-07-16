# frozen_string_literal: true

require "tempfile"

module HoneycombRegistry
  module AtomicWrite
    module_function

    def replace(path, bytes, mode: 0o644)
      directory = File.dirname(path)
      basename = File.basename(path)
      temporary = Tempfile.new([".#{basename}.", ".tmp"], directory, mode: File::RDWR)
      begin
        temporary.binmode
        temporary.write(bytes)
        temporary.flush
        temporary.fsync
        temporary.chmod(mode)
        temporary.close
        File.rename(temporary.path, path)
        fsync_directory(directory)
      ensure
        temporary.close! if temporary
      end
    end

    def fsync_directory(directory)
      File.open(directory, File::RDONLY) { |file| file.fsync }
    rescue Errno::EINVAL, Errno::ENOTSUP
      nil
    end
  end
end
