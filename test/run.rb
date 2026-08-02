# frozen_string_literal: true

standalone_tests = [
  File.expand_path("root_cause_repair_candidate_hive_execution_test.rb", __dir__)
].freeze

Dir[File.expand_path("**/*_test.rb", __dir__)].sort.each do |file|
  require file unless standalone_tests.include?(file)
end
