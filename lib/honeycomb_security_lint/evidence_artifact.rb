# frozen_string_literal: true

require "digest"

module HoneycombSecurityLint
  class EvidenceArtifact
    ARTIFACT_NAME = "security-lint-evidence"

    class Invalid < StandardError; end

    def initialize(client:, policy:)
      @client = client
      @policy = policy
    end

    def load(run_id)
      artifacts = @client.artifacts(run_id).select do |artifact|
        artifact["name"] == ARTIFACT_NAME && artifact["expired"] == false
      end
      raise Invalid, "expected exactly one security lint evidence artifact" unless artifacts.length == 1

      artifact = artifacts.first
      size = artifact["size_in_bytes"]
      max_archive = @policy.limits.fetch("max_artifact_bytes") + 262_144
      unless size.is_a?(Integer) && size.positive? && size <= max_archive
        raise Invalid, "security lint evidence artifact size is invalid"
      end
      digest = artifact["digest"]
      unless digest.is_a?(String) && digest.match?(/\Asha256:[0-9a-f]{64}\z/)
        raise Invalid, "security lint evidence artifact digest is missing"
      end

      archive = @client.download_artifact(artifact.fetch("archive_download_url"))
      raise Invalid, "security lint evidence artifact size changed" unless archive.bytesize == size
      actual = Digest::SHA256.hexdigest(archive)
      raise Invalid, "security lint evidence artifact digest changed" unless digest == "sha256:#{actual}"

      json = ArtifactArchive.evidence_json(
        archive, max_bytes: @policy.limits.fetch("max_artifact_bytes")
      )
      evidence = Contracts.parse_evidence(json)
      unless Contracts.artifact_digest_valid?(evidence)
        raise Invalid, "security lint evidence content digest is invalid"
      end
      evidence
    rescue KeyError
      raise Invalid, "security lint evidence artifact metadata is incomplete"
    end
  end
end
