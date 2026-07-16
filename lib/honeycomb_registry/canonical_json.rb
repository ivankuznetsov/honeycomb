# frozen_string_literal: true

require "json"

module HoneycombRegistry
  module CanonicalJSON
    module_function

    def dump(value)
      JSON.pretty_generate(value, allow_nan: false) + "\n"
    end
  end
end
