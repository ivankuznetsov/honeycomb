# frozen_string_literal: true

require "json"
require "net/http"
require "timeout"
require "uri"

module HoneycombSecurityLint
  class GitHubClient
    class Error < StandardError; end

    def initialize(repository:, token:, api_url: "https://api.github.com")
      @repository = repository
      @token = token
      @api_uri = URI.parse(api_url)
      unless @api_uri.is_a?(URI::HTTPS) && @api_uri.userinfo.nil?
        raise Error, "GitHub API URL must be safe HTTPS"
      end
      raise Error, "GitHub token is missing" if token.to_s.empty?
    end

    def pull(number)
      get_json(repo_path("pulls/#{number}"))
    end

    def pull_files(number)
      paginate(repo_path("pulls/#{number}/files"), key: nil).map { |entry| entry.fetch("filename") }
    end

    def artifacts(run_id)
      paginate(repo_path("actions/runs/#{run_id}/artifacts"), key: "artifacts")
    end

    def comments(number)
      paginate(repo_path("issues/#{number}/comments"), key: nil)
    end

    def create_comment(number, body)
      request_json(:post, repo_path("issues/#{number}/comments"), {"body" => body}, expected: [201])
    end

    def update_comment(id, body)
      request_json(:patch, repo_path("issues/comments/#{Integer(id)}"), {"body" => body}, expected: [200])
    end

    def create_status(sha, attributes)
      request_json(:post, repo_path("statuses/#{sha}"), attributes, expected: [201])
    end

    def remove_label(number, label)
      encoded = URI.encode_www_form_component(label)
      request_json(:delete, repo_path("issues/#{number}/labels/#{encoded}"), nil, expected: [200, 404])
    end

    def download_artifact(url)
      uri = URI.parse(url)
      unless uri.is_a?(URI::HTTPS) && uri.userinfo.nil?
        raise Error, "artifact URL must be safe HTTPS"
      end
      get_bytes(uri, redirects: 3, authorize: uri.host == @api_uri.host)
    rescue URI::InvalidURIError
      raise Error, "artifact URL is invalid"
    end

    private

    def repo_path(suffix)
      "/repos/#{@repository}/#{suffix}"
    end

    def paginate(path, key:)
      page = 1
      values = []
      loop do
        separator = path.include?("?") ? "&" : "?"
        document = get_json("#{path}#{separator}per_page=100&page=#{page}")
        entries = key ? document.fetch(key) : document
        raise Error, "GitHub API pagination response is invalid" unless entries.is_a?(Array)
        values.concat(entries)
        break if entries.length < 100
        page += 1
        raise Error, "GitHub API pagination limit exceeded" if page > 100
      end
      values
    end

    def get_json(path)
      request_json(:get, path, nil, expected: [200])
    end

    def request_json(method, path, body, expected:)
      uri = @api_uri + path
      response = request(method, uri, body && JSON.generate(body), authorize: true)
      raise Error, "GitHub API returned HTTP #{response.code}" unless expected.include?(response.code.to_i)
      return {} if response.body.to_s.empty?

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, "GitHub API returned malformed JSON"
    end

    def get_bytes(uri, redirects:, authorize:)
      response = request(:get, uri, nil, authorize: authorize)
      if response.is_a?(Net::HTTPRedirection)
        raise Error, "artifact redirect limit exceeded" if redirects.zero?
        redirected = URI.parse(response.fetch("location"))
        unless redirected.is_a?(URI::HTTPS) && redirected.userinfo.nil?
          raise Error, "artifact redirect is unsafe"
        end
        return get_bytes(redirected, redirects: redirects - 1, authorize: redirected.host == @api_uri.host)
      end
      raise Error, "artifact download returned HTTP #{response.code}" unless response.code.to_i == 200
      response.body.to_s.b
    rescue URI::InvalidURIError
      raise Error, "artifact redirect is invalid"
    end

    def request(method, uri, body, authorize:)
      request_class = {
        get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch,
        delete: Net::HTTP::Delete
      }.fetch(method)
      message = request_class.new(uri)
      message["Accept"] = "application/vnd.github+json"
      message["X-GitHub-Api-Version"] = "2022-11-28"
      message["User-Agent"] = "honeycomb-security-lint-reporter"
      message["Authorization"] = "Bearer #{@token}" if authorize
      if body
        message["Content-Type"] = "application/json"
        message.body = body
      end
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        http.request(message)
      end
    rescue SystemCallError, IOError, Timeout::Error => e
      raise Error, "GitHub API request failed: #{e.class}"
    end
  end
end
