# frozen_string_literal: true

require "ipaddr"
require "shellwords"
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
    CURL_VALUE_OPTIONS = %w[
      -A --data --data-ascii --data-binary --data-raw --data-urlencode --form --header
      --output --referer --request --user --user-agent -d -e -F -H -o -u -X
    ].freeze
    WGET_VALUE_OPTIONS = %w[
      --header --output-document --referer --user --user-agent -e -o -O -U
    ].freeze
    POWERSHELL_VALUE_OPTIONS = %w[-Headers -Method -OutFile -UserAgent].map(&:downcase).freeze

    class LimitExceeded < StandardError; end

    def initialize(max_observations: nil)
      @max_observations = max_observations
    end

    def extract(commands)
      observations = []
      commands.each do |command|
        extract_command(command, observations)
      end
      observations.uniq { |entry| [entry.host, entry.path, entry.line, entry.column] }
                  .sort_by { |entry| [entry.path, entry.line, entry.column, entry.host] }
    end

    private

    def extract_command(command, observations)
      observation_start = observations.length
      command.raw.to_enum(:scan, URL_PATTERN).each do
        match = Regexp.last_match
        raw = match[0].sub(/[),.;]+\z/, "")
        append_observation(observations) { observation(command, raw, match.begin(0) + 1) }
      end
      unresolved_fallback = observations.length == observation_start
      if command.raw.match?(NETWORK_COMMAND) && (destination = dynamic_destination(command.raw, unresolved_fallback))
        append_observation(observations) do
          Observation.new(
            host: destination, dynamic: true, path: command.path, line: command.line,
            column: command.column, raw: destination
          )
        end
      end
    end

    def append_observation(observations)
      if @max_observations && observations.length >= @max_observations
        raise LimitExceeded, "network observation count exceeds policy"
      end
      observations << yield
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

    def dynamic_destination(raw, unresolved_fallback)
      tokens = Shellwords.shellsplit(raw)
      command_index = tokens.index { |token| NETWORK_COMMAND.match?(token) }
      return "<unresolved>" if unresolved_fallback && command_index.nil?

      client = network_client(tokens.fetch(command_index))
      arguments = tokens.drop(command_index + 1)
      index = 0
      while index < arguments.length
        token = arguments[index]
        option, attached_value = token.split("=", 2)
        if destination_option?(client, option)
          value = attached_value || arguments[index + 1]
          return "<dynamic>" if dynamic_token?(value)
          index += attached_value ? 1 : 2
          next
        end
        if token.start_with?("-")
          consumes_separate_value = attached_value.nil? && value_option?(client, token)
          index += consumes_separate_value ? 2 : 1
          next
        end
        return "<dynamic>" if dynamic_token?(token)

        index += 1
      end

      "<unresolved>" if unresolved_fallback
    rescue ArgumentError
      "<dynamic>"
    end

    def network_client(token)
      File.basename(token).downcase
    end

    def destination_option?(client, option)
      (client == "curl" && option == "--url") ||
        (%w[iwr invoke-webrequest].include?(client) && option.casecmp?("-Uri"))
    end

    def value_option?(client, token)
      case client
      when "curl"
        CURL_VALUE_OPTIONS.include?(token)
      when "wget"
        WGET_VALUE_OPTIONS.include?(token)
      when "iwr", "invoke-webrequest"
        POWERSHELL_VALUE_OPTIONS.include?(token.downcase)
      else
        false
      end
    end

    def dynamic_token?(token)
      token.to_s.match?(/\$|\{\{|%[A-Za-z_]+%/)
    end
  end
end
