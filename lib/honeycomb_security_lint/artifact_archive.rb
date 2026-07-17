# frozen_string_literal: true

require "zlib"

module HoneycombSecurityLint
  module ArtifactArchive
    EOCD_SIGNATURE = "PK\x05\x06".b
    CENTRAL_SIGNATURE = 0x02014b50
    LOCAL_SIGNATURE = 0x04034b50
    MAX_EOCD_SEARCH = 65_557

    class Invalid < StandardError; end

    module_function

    def evidence_json(archive, max_bytes:)
      bytes = archive.to_s.b
      eocd = bytes.rindex(EOCD_SIGNATURE)
      raise Invalid, "artifact is not a supported ZIP archive" unless eocd && eocd >= [bytes.bytesize - MAX_EOCD_SEARCH, 0].max
      raise Invalid, "artifact end record is truncated" if eocd + 22 > bytes.bytesize

      disk = u16(bytes, eocd + 4)
      central_disk = u16(bytes, eocd + 6)
      disk_entries = u16(bytes, eocd + 8)
      entries = u16(bytes, eocd + 10)
      central_size = u32(bytes, eocd + 12)
      central_offset = u32(bytes, eocd + 16)
      comment_size = u16(bytes, eocd + 20)
      unless disk.zero? && central_disk.zero? && disk_entries == 1 && entries == 1
        raise Invalid, "artifact must be a single-entry, non-spanned ZIP archive"
      end
      raise Invalid, "artifact ZIP comment is malformed" unless eocd + 22 + comment_size == bytes.bytesize
      raise Invalid, "artifact central directory is malformed" unless central_offset + central_size == eocd
      raise Invalid, "artifact central directory is truncated" if central_offset + 46 > eocd
      raise Invalid, "artifact central entry is invalid" unless u32(bytes, central_offset) == CENTRAL_SIGNATURE

      flags = u16(bytes, central_offset + 8)
      compression = u16(bytes, central_offset + 10)
      crc = u32(bytes, central_offset + 16)
      compressed_size = u32(bytes, central_offset + 20)
      uncompressed_size = u32(bytes, central_offset + 24)
      name_size = u16(bytes, central_offset + 28)
      extra_size = u16(bytes, central_offset + 30)
      entry_comment_size = u16(bytes, central_offset + 32)
      disk_start = u16(bytes, central_offset + 34)
      external_attributes = u32(bytes, central_offset + 38)
      local_offset = u32(bytes, central_offset + 42)
      central_end = central_offset + 46 + name_size + extra_size + entry_comment_size
      raise Invalid, "artifact contains extra central entries" unless central_end == eocd
      raise Invalid, "artifact entry starts on another disk" unless disk_start.zero?
      raise Invalid, "artifact entry is encrypted or uses unsupported ZIP flags" unless (flags & ~0x0808).zero? && (flags & 1).zero?
      raise Invalid, "artifact compression is unsupported" unless [0, 8].include?(compression)
      raise Invalid, "artifact evidence exceeds the uncompressed size limit" if uncompressed_size > max_bytes

      name = bytes.byteslice(central_offset + 46, name_size).to_s.force_encoding(Encoding::UTF_8)
      raise Invalid, "artifact entry name is invalid UTF-8" unless name.valid_encoding?
      raise Invalid, "artifact must contain exactly evidence.json" unless name == "evidence.json"
      mode = (external_attributes >> 16) & 0xffff
      file_type = mode & 0o170000
      raise Invalid, "artifact entry is not a regular file" unless file_type.zero? || file_type == 0o100000

      read_local_entry(bytes, local_offset, name, flags, compression, compressed_size,
                       uncompressed_size, crc, max_bytes)
    rescue RangeError
      raise Invalid, "artifact ZIP integer is out of range"
    end

    def read_local_entry(bytes, offset, expected_name, expected_flags, compression,
                         compressed_size, uncompressed_size, crc, max_bytes)
      raise Invalid, "artifact local entry is truncated" if offset + 30 > bytes.bytesize
      raise Invalid, "artifact local entry is invalid" unless u32(bytes, offset) == LOCAL_SIGNATURE
      flags = u16(bytes, offset + 6)
      local_compression = u16(bytes, offset + 8)
      name_size = u16(bytes, offset + 26)
      extra_size = u16(bytes, offset + 28)
      raise Invalid, "artifact local entry disagrees with central metadata" unless flags == expected_flags && local_compression == compression
      name = bytes.byteslice(offset + 30, name_size).to_s.force_encoding(Encoding::UTF_8)
      raise Invalid, "artifact local name is invalid" unless name.valid_encoding? && name == expected_name
      data_offset = offset + 30 + name_size + extra_size
      raise Invalid, "artifact compressed data is truncated" if data_offset + compressed_size > bytes.bytesize
      compressed = bytes.byteslice(data_offset, compressed_size)
      output = compression.zero? ? compressed : inflate(compressed, max_bytes)
      raise Invalid, "artifact evidence size disagrees with ZIP metadata" unless output.bytesize == uncompressed_size
      raise Invalid, "artifact evidence checksum is invalid" unless Zlib.crc32(output) == crc

      output
    end

    def inflate(compressed, max_bytes)
      output = String.new(capacity: [max_bytes, 65_536].min, encoding: Encoding::BINARY)
      inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
      compressed.bytes.each_slice(16_384) do |slice|
        inflater.inflate(slice.pack("C*")) do |chunk|
          output << chunk
          raise Invalid, "artifact evidence exceeds the uncompressed size limit" if output.bytesize > max_bytes
        end
      end
      tail = inflater.finish
      output << tail if tail
      raise Invalid, "artifact evidence exceeds the uncompressed size limit" if output.bytesize > max_bytes
      output
    rescue Zlib::Error
      raise Invalid, "artifact deflate stream is invalid"
    ensure
      inflater&.close
    end

    def u16(bytes, offset)
      value = bytes.byteslice(offset, 2)
      raise Invalid, "artifact ZIP field is truncated" unless value&.bytesize == 2
      value.unpack1("v")
    end

    def u32(bytes, offset)
      value = bytes.byteslice(offset, 4)
      raise Invalid, "artifact ZIP field is truncated" unless value&.bytesize == 4
      value.unpack1("V")
    end
  end
end
