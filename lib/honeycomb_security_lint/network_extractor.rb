# frozen_string_literal: true

require "ipaddr"
require "uri"

module HoneycombSecurityLint
  class NetworkExtractor
    Observation = Struct.new(:host, :dynamic, :path, :line, :column, :raw, keyword_init: true) do
      def evidence(declared:, reason:, disposition:)
        {
          "host" => host,
          "path" => path,
          "line" => line,
          "column" => column,
          "declared" => declared,
          "reason" => reason,
          "disposition" => disposition
        }
      end
    end

    URL_PATTERN = %r{https?://[^\s"'<>|`]+}i
    NETWORK_COMMAND = /\b(?:curl|wget|iwr|invoke-webrequest)\b/i

    def extract(commands)
      commands.flat_map { |command| extract_command(command) }
              .uniq { |entry| [entry.host, entry.path, entry.line, entry.column] }
              .sort_by { |entry| [entry.path, entry.line, entry.column, entry.host] }
    end

    private

    def extract_command(command)
      observations = []
      command.raw.to_enum(:scan, URL_PATTERN).each do
        match = Regexp.last_match
        raw = match[0].sub(/[),.;]+\z/, "")
        observations << observation(command, raw, match.begin(0) + 1)
      end
      if observations.empty? && command.raw.match?(NETWORK_COMMAND)
        destination = dynamic_destination(command.raw)
        observations << Observation.new(
          host: destination, dynamic: true, path: command.path, line: command.line,
          column: command.column, raw: destination
        )
      end
      observations
    end

    def observation(command, raw, offset)
      dynamic = raw.match?(/\$|\{\{|%[A-Za-z_]+%/)
      host = if dynamic
               "<dynamic>"
             else
               normalize_uri(raw)
             end
      Observation.new(host: host, dynamic: dynamic, path: command.path, line: command.line,
                      column: command.column + offset - 1, raw: raw)
    rescue URI::InvalidURIError
      Observation.new(host: "<invalid>", dynamic: true, path: command.path, line: command.line,
                      column: command.column + offset - 1, raw: raw)
    end

    def normalize_uri(raw)
      uri = URI.parse(raw)
      raise URI::InvalidURIError if uri.userinfo || uri.host.nil?

      host = uri.host.downcase.sub(/\.$/, "")
      port = uri.port
      default = (uri.scheme.downcase == "https" ? 443 : 80)
      port == default ? host : "#{host}:#{port}"
    end

    def dynamic_destination(raw)
      token = raw.split.find { |entry| entry.match?(/\$|\{\{|%[A-Za-z_]+%/) }
      token ? "<dynamic>" : "<unresolved>"
    end
  end
end
