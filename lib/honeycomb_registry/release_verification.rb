# frozen_string_literal: true

require "digest"

module HoneycombRegistry
  module ReleaseVerification
    module_function

    def archive_sha256(manifest)
      projection = {
        "release_sha256" => manifest.fetch("release_sha256"),
        "files" => manifest.fetch("files").sort.to_h
      }
      Digest::SHA256.hexdigest(CanonicalJSON.dump(projection))
    end
  end
end
