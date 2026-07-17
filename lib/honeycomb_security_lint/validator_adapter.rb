# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "timeout"

module HoneycombSecurityLint
  class ValidatorAdapter
    Result = Struct.new(:exit_status, :findings, :operational_error, keyword_init: true) do
      def error?
        !operational_error.nil?
      end
    end

    FINDING_KEYS = %w[path code message severity].freeze

    def initialize(root:, executable: nil, timeout_seconds: 30, executor: nil)
      @root = File.expand_path(root)
      @executable = File.expand_path(executable || File.join(@root, "script", "honeycomb-validate"))
      @timeout_seconds = timeout_seconds
      @executor = executor
    end

    def validate(package_path)
      unless File.file?(@executable)
        return Result.new(exit_status: 2, findings: [], operational_error: "validator executable is missing")
      end
      stdout, stderr, status = if @executor
                                 @executor.call([RbConfig.ruby, @executable, "--root", @root, "--json", package_path])
                               else
                                 execute([RbConfig.ruby, @executable, "--root", @root, "--json", package_path])
                               end
      exit_status = status.respond_to?(:exitstatus) ? status.exitstatus : Integer(status)
      unless [0, 1, 2].include?(exit_status)
        return Result.new(exit_status: 2, findings: [], operational_error: "validator returned unsupported exit #{exit_status}")
      end
      findings = parse_findings(stdout)
      if exit_status == 2
        return Result.new(exit_status: 2, findings: findings,
                          operational_error: "validator invocation failed#{": #{sanitize(stderr)}" unless stderr.to_s.empty?}")
      end
      if exit_status.zero? && findings.any? { |finding| finding["severity"] == "error" }
        return Result.new(exit_status: 2, findings: [], operational_error: "validator exit disagrees with error findings")
      end
      if exit_status == 1 && findings.none? { |finding| finding["severity"] == "error" }
        return Result.new(exit_status: 2, findings: [], operational_error: "validator exit 1 did not include an error finding")
      end
      Result.new(exit_status: exit_status, findings: findings.sort_by { |entry| FINDING_KEYS.map { |key| entry[key].to_s } })
    rescue Contracts::Invalid => e
      Result.new(exit_status: 2, findings: [], operational_error: e.message)
    rescue Timeout::Error
      Result.new(exit_status: 2, findings: [], operational_error: "validator timed out")
    rescue SystemCallError, IOError, ArgumentError => e
      Result.new(exit_status: 2, findings: [], operational_error: "validator could not run: #{e.class}")
    end

    private

    def execute(argv)
      input = output = error = wait_thread = nil
      output_reader = error_reader = nil
      input, output, error, wait_thread = Open3.popen3(*argv, chdir: @root, pgroup: true)
      input.close
      output_reader = Thread.new { output.read }
      error_reader = Thread.new { error.read }
      unless wait_thread.join(@timeout_seconds)
        terminate_group(wait_thread)
        raise Timeout::Error, "validator deadline exceeded"
      end
      [output_reader.value, error_reader.value, wait_thread.value]
    ensure
      [input, output, error].compact.each { |stream| stream.close unless stream.closed? }
      [output_reader, error_reader].compact.each { |reader| reader.join(1) }
    end

    def terminate_group(wait_thread)
      Process.kill("TERM", -wait_thread.pid)
      return if wait_thread.join(1)

      Process.kill("KILL", -wait_thread.pid)
      wait_thread.join
    rescue Errno::ESRCH
      nil
    end

    def parse_findings(source)
      parsed = Contracts.parse_json(source)
      raise Contracts::Invalid, "validator JSON root must be an array" unless parsed.is_a?(Array)

      parsed.each_with_index.map do |finding, index|
        unless finding.is_a?(Hash) && finding.keys.sort == FINDING_KEYS.sort
          raise Contracts::Invalid, "validator finding #{index} must contain exactly #{FINDING_KEYS.join(', ')}"
        end
        unless finding.values_at(*FINDING_KEYS).all? { |value| value.is_a?(String) }
          raise Contracts::Invalid, "validator finding #{index} fields must be strings"
        end
        unless %w[error warning info].include?(finding["severity"])
          raise Contracts::Invalid, "validator finding #{index} has unsupported severity"
        end
        finding.to_h
      end
    end

    def sanitize(value)
      value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
           .gsub(/[\r\n\x00-\x1f\x7f]+/, " ").byteslice(0, 200).to_s
    end
  end
end
