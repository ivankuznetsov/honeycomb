# frozen_string_literal: true

module HoneycombSecurityLint
  module InstructionScope
    INSTRUCTION_EXTENSION = /\.(?:md|txt|ya?ml)\z/

    module_function

    def include?(repository_path, version_root)
      prefix = "#{version_root}/"
      return false unless repository_path.start_with?(prefix)

      relative = repository_path.delete_prefix(prefix)
      return true if relative == "workflow.yml" || relative == "README.md"

      relative.start_with?("instructions/") && INSTRUCTION_EXTENSION.match?(relative)
    end
  end
end
