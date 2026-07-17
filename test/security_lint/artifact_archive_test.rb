# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintArtifactArchiveTest < Minitest::Test
  def zip(bytes, compression: 8, declared_size: bytes.bytesize, external_attributes: 0o100644 << 16)
    compressed = if compression.zero?
                   bytes
                 else
                   deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
                   begin
                     deflater.deflate(bytes, Zlib::FINISH)
                   ensure
                     deflater.close
                   end
                 end
    name = "evidence.json"
    crc = Zlib.crc32(bytes)
    local = [0x04034b50, 20, 0, compression, 0, 0, crc, compressed.bytesize, declared_size, name.bytesize, 0]
            .pack("VvvvvvVVVvv") + name + compressed
    central = [0x02014b50, 0x0314, 20, 0, compression, 0, 0, crc, compressed.bytesize, declared_size,
               name.bytesize, 0, 0, 0, 0, external_attributes, 0]
              .pack("VvvvvvvVVVvvvvvVV") + name
    local + central + [0x06054b50, 0, 0, 1, 1, central.bytesize, local.bytesize, 0].pack("VvvvvVVv")
  end

  def test_reads_bounded_stored_and_deflated_single_file_archives
    bytes = "{\"schema\":\"fixture\"}\n"

    assert_equal bytes, HoneycombSecurityLint::ArtifactArchive.evidence_json(zip(bytes, compression: 0), max_bytes: 1024)
    assert_equal bytes, HoneycombSecurityLint::ArtifactArchive.evidence_json(zip(bytes), max_bytes: 1024)
  end

  def test_rejects_declared_zip_bombs_and_symlinks
    assert_raises(HoneycombSecurityLint::ArtifactArchive::Invalid) do
      HoneycombSecurityLint::ArtifactArchive.evidence_json(zip("tiny", declared_size: 10_000), max_bytes: 100)
    end
    assert_raises(HoneycombSecurityLint::ArtifactArchive::Invalid) do
      HoneycombSecurityLint::ArtifactArchive.evidence_json(
        zip("tiny", external_attributes: 0o120777 << 16), max_bytes: 100
      )
    end
  end


  def test_streaming_limit_rejects_deflate_output_larger_than_declared_size
    archive = zip("a" * 1_000, declared_size: 100)

    error = assert_raises(HoneycombSecurityLint::ArtifactArchive::Invalid) do
      HoneycombSecurityLint::ArtifactArchive.evidence_json(archive, max_bytes: 100)
    end
    assert_equal "artifact evidence exceeds the uncompressed size limit", error.message
  end
end
