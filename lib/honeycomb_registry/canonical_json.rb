# frozen_string_literal: true

require "json"

module HoneycombRegistry
  module CanonicalJSON
    module_function

    def dump(value)
      normalize_empty_containers(JSON.pretty_generate(value, allow_nan: false)) + "\n"
    end

    def normalize_empty_containers(bytes)
      bytes.gsub(/\[\n[[:space:]]*\]/, "[]")
           .gsub(/\{\n[[:space:]]*\}/, "{}")
    end
  end
end
