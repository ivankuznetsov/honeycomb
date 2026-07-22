# frozen_string_literal: true

require "json"
require "fileutils"

honeycomb_root, registry_root = ARGV
abort "usage: build_registry.rb HONEYCOMB_ROOT REGISTRY_ROOT" unless honeycomb_root && registry_root

honeycomb_root = File.expand_path(honeycomb_root)
registry_root = File.expand_path(registry_root)
$LOAD_PATH.unshift(File.join(honeycomb_root, "lib"))

require "honeycomb_registry"
require File.join(honeycomb_root, "test", "support", "async_fix_registry")

builder = Object.new.extend(AsyncFixRegistrySupport)
FileUtils.mkdir_p(registry_root, mode: 0o700)
registry = builder.build_async_fix_registry(
  registry_root,
  candidate_root: File.join(honeycomb_root, "candidates", "async-fix")
)
puts JSON.generate({
  "root" => registry.root,
  "source_revision" => registry.source_revision,
  "release_revision" => registry.release_revision,
  "catalog_commit" => registry.catalog_commit,
  "manifest_digest" => registry.manifest.fetch("release_sha256")
})
