# frozen_string_literal: true

module HoneycombSecurityLint
  module InstructionScope
    module_function

    def include?(repository_path, version_root, behavior_paths: [])
      prefix = "#{version_root}/"
      return false unless repository_path.start_with?(prefix)
      return true if behavior_paths.include?(repository_path)

      relative = repository_path.delete_prefix(prefix)
      return true if relative == "workflow.yml" || relative == "README.md"

      relative.start_with?("instructions/")
    end
  end
end
