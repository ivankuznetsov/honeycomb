# frozen_string_literal: true

require_relative "honeycomb_registry/findings"
require_relative "honeycomb_registry/safe_yaml"
require_relative "honeycomb_registry/semver"
require_relative "honeycomb_registry/schema"
require_relative "honeycomb_registry/permissions"
require_relative "honeycomb_registry/atomic_write"
require_relative "honeycomb_registry/canonical_yaml"
require_relative "honeycomb_registry/package"
require_relative "honeycomb_registry/manifest"
require_relative "honeycomb_registry/hive_compatibility"
require_relative "honeycomb_registry/validator"
require_relative "honeycomb_registry/canonical_json"
require_relative "honeycomb_registry/release_verification"
require_relative "honeycomb_registry/listing_evidence"
require_relative "honeycomb_registry/catalog"

module HoneycombRegistry
  class InvocationError < StandardError; end
end
