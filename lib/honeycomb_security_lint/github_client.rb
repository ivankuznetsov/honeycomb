# frozen_string_literal: true

require "json"
require "base64"
require "net/http"
require "timeout"
require "uri"

module HoneycombSecurityLint
  class GitHubClient
    class Error < StandardError; end
    class NotFound < Error; end
    class Conflict < Error; end

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

    def pull_files(number, expected_count:)
      count = Integer(expected_count)
      raise Error, "pull changed-files count is invalid" if count.negative?

      files = paginate(repo_path("pulls/#{number}/files"), key: nil).map { |entry| entry.fetch("filename") }
      unless files.length == count
        raise Error, "GitHub pull file list is incomplete"
      end
      files
    rescue ArgumentError, TypeError
      raise Error, "pull changed-files count is invalid"
    end

    def pull_review(number, review_id)
      get_json(repo_path("pulls/#{Integer(number)}/reviews/#{Integer(review_id)}"))
    end

    def pull_reviews(number)
      paginate(repo_path("pulls/#{Integer(number)}/reviews"), key: nil)
    end

    def workflow_runs(workflow, head_sha:)
      encoded_workflow = URI.encode_www_form_component(workflow.to_s)
      encoded_sha = URI.encode_www_form_component(head_sha.to_s)
      paginate(repo_path("actions/workflows/#{encoded_workflow}/runs?event=pull_request&head_sha=#{encoded_sha}"),
               key: "workflow_runs")
    end

    def workflow_run(run_id)
      get_json(repo_path("actions/runs/#{Integer(run_id)}"))
    rescue ArgumentError, TypeError
      raise Error, "workflow run ID is invalid"
    end

    def collaborator_permission(login)
      encoded = URI.encode_www_form_component(login.to_s)
      get_json(repo_path("collaborators/#{encoded}/permission")).fetch("permission")
    end

    def commit_statuses(sha)
      paginate(repo_path("commits/#{sha}/statuses"), key: nil)
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

    def ensure_branch(branch, base_branch:)
      encoded_branch = branch.split("/").map { |part| URI.encode_www_form_component(part) }.join("/")
      get_json(repo_path("git/ref/heads/#{encoded_branch}"))
      true
    rescue NotFound
      encoded_base = base_branch.split("/").map { |part| URI.encode_www_form_component(part) }.join("/")
      base = get_json(repo_path("git/ref/heads/#{encoded_base}"))
      sha = base.dig("object", "sha")
      raise Error, "default branch ref is invalid" unless sha.is_a?(String) && sha.match?(/\A[0-9a-f]{40}\z/)

      request_json(
        :post, repo_path("git/refs"), {"ref" => "refs/heads/#{branch}", "sha" => sha},
        expected: [201]
      )
      true
    rescue Conflict
      true
    end

    def create_content(path, bytes:, branch:, message:)
      request_json(
        :put, repo_path("contents/#{encode_path(path)}"),
        {
          "message" => message, "content" => Base64.strict_encode64(bytes),
          "branch" => branch
        },
        expected: [201]
      )
    end

    def content(path, ref:)
      encoded_ref = URI.encode_www_form_component(ref)
      document = get_json("#{repo_path("contents/#{encode_path(path)}")}?ref=#{encoded_ref}")
      unless document["encoding"] == "base64" && document["content"].is_a?(String)
        raise Error, "GitHub content response is invalid"
      end
      Base64.strict_decode64(document.fetch("content").gsub(/\s+/, ""))
    rescue ArgumentError
      raise Error, "GitHub content response is invalid"
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

    def encode_path(path)
      path.to_s.split("/").map { |part| URI.encode_www_form_component(part) }.join("/")
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
      unless expected.include?(response.code.to_i)
        raise NotFound, "GitHub API returned HTTP 404" if response.code.to_i == 404
        raise Conflict, "GitHub API returned HTTP #{response.code}" if [409, 422].include?(response.code.to_i)
        raise Error, "GitHub API returned HTTP #{response.code}"
      end
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
        get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put, patch: Net::HTTP::Patch,
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
