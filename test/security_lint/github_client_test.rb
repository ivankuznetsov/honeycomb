# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintGitHubClientTest < Minitest::Test
  class StubClient < HoneycombSecurityLint::GitHubClient
    attr_reader :requests
    attr_accessor :responses, :pages

    def initialize
      super(repository: "hive-sh/honeycomb", token: "test-token", api_url: "https://api.github.test")
      @requests = []
      @responses = []
      @pages = []
    end

    private

    def request(method, uri, body, authorize:)
      requests << [method, uri.to_s, body, authorize]
      responses.shift || raise("missing stub response")
    end

    def paginate(_path, key:)
      key
      pages
    end
  end

  def response(type, location: nil, body: nil)
    value = type.new("1.1", type == Net::HTTPOK ? "200" : "302", "stub")
    value["location"] = location if location
    value.instance_variable_set(:@read, true)
    value.body = body if body
    value
  end

  def test_cross_host_redirect_strips_token_but_same_host_retains_it
    client = StubClient.new
    client.responses = [
      response(Net::HTTPFound, location: "https://objects.example.test/archive.zip"),
      response(Net::HTTPOK, body: "zip")
    ]

    assert_equal "zip", client.download_artifact("https://api.github.test/archive")
    assert_equal [true, false], client.requests.map(&:last)

    client = StubClient.new
    client.responses = [
      response(Net::HTTPFound, location: "https://api.github.test/redirected"),
      response(Net::HTTPOK, body: "zip")
    ]
    client.download_artifact("https://api.github.test/archive")
    assert_equal [true, true], client.requests.map(&:last)
  end

  def test_unsafe_redirect_is_rejected_without_following_it
    client = StubClient.new
    client.responses = [response(Net::HTTPFound, location: "http://objects.example.test/archive.zip")]

    assert_raises(HoneycombSecurityLint::GitHubClient::Error) do
      client.download_artifact("https://api.github.test/archive")
    end
    assert_equal 1, client.requests.length
  end

  def test_pull_file_count_must_match_authoritative_pull_metadata
    client = StubClient.new
    client.pages = [{"filename" => "packages/example/1.0.0/README.md"}]

    assert_equal ["packages/example/1.0.0/README.md"], client.pull_files(42, expected_count: 1)
    assert_raises(HoneycombSecurityLint::GitHubClient::Error) do
      client.pull_files(42, expected_count: 2)
    end
  end

  def test_fetches_one_workflow_run_by_its_numeric_identity
    client = StubClient.new
    client.responses = [response(Net::HTTPOK, body: JSON.generate({"id" => 88}))]

    assert_equal({"id" => 88}, client.workflow_run(88))
    assert_equal "https://api.github.test/repos/hive-sh/honeycomb/actions/runs/88",
                 client.requests.first[1]
  end

  def test_checks_exact_commit_ancestry_with_github_compare
    client = StubClient.new
    client.responses = [
      response(Net::HTTPOK, body: JSON.generate({"status" => "ahead"})),
      response(Net::HTTPOK, body: JSON.generate({"status" => "identical"})),
      response(Net::HTTPOK, body: JSON.generate({"status" => "diverged"}))
    ]

    assert client.commit_ancestor?("a" * 40, "b" * 40)
    assert client.commit_ancestor?("a" * 40, "a" * 40)
    refute client.commit_ancestor?("a" * 40, "c" * 40)
    assert_equal(
      "https://api.github.test/repos/hive-sh/honeycomb/compare/#{"a" * 40}...#{"b" * 40}",
      client.requests.first[1]
    )
  end
end
