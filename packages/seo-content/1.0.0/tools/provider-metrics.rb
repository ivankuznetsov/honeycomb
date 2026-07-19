#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "date"
require "json"
require "net/http"
require "time"
require "uri"

module SeoProviderMetrics
  MAX_INPUT_BYTES = 65_536
  MAX_RESPONSE_BYTES = 1_048_576
  MAX_KEYWORDS = 50
  CONNECT_TIMEOUT = 5
  READ_TIMEOUT = 10
  PROVIDER_ORIGINS = {
    "ahrefs" => "https://api.ahrefs.com",
    "dataforseo" => "https://api.dataforseo.com",
    "ga4" => "https://analyticsdata.googleapis.com",
    "gsc" => "https://www.googleapis.com"
  }.freeze
  ALLOWED_HOSTS = PROVIDER_ORIGINS.values.map { |origin| URI(origin).host }.freeze

  module_function

  def run(input: STDIN, output: STDOUT, environment: ENV)
    request = parse_input(input.read(MAX_INPUT_BYTES + 1))
    providers = {
      "ahrefs" => ahrefs(request, environment),
      "dataforseo" => dataforseo(request, environment),
      "ga4" => ga4(request, environment),
      "gsc" => gsc(request, environment)
    }
    successes = providers.count { |_name, result| result["status"] == "ok" }
    attempted = providers.count { |_name, result| result["status"] != "missing" }
    mode = if successes.zero? && attempted.zero?
      "prompt-only"
    elsif successes == attempted && successes.positive?
      "provider-backed"
    else
      "partial"
    end
    output.puts(JSON.generate({
      "schema" => "seo-provider-metrics/v1",
      "mode" => mode,
      "queried_at" => Time.now.utc.iso8601,
      "providers" => providers
    }))
    0
  rescue ArgumentError, JSON::ParserError => e
    output.puts(JSON.generate({
      "schema" => "seo-provider-metrics/v1", "mode" => "error",
      "error" => safe_error(e)
    }))
    2
  end

  def parse_input(bytes)
    raise ArgumentError, "input exceeds #{MAX_INPUT_BYTES} bytes" if bytes.bytesize > MAX_INPUT_BYTES

    value = JSON.parse(bytes)
    raise ArgumentError, "input must be a JSON object" unless value.is_a?(Hash)

    keywords = Array(value["keywords"]).map { |item| item.to_s.strip }.reject(&:empty?).uniq.first(MAX_KEYWORDS)
    unless keywords.all? { |keyword| keyword.length <= 80 && keyword.split.length <= 10 }
      raise ArgumentError, "keywords must be at most 80 characters and 10 words"
    end
    site_url = value["site_url"].to_s.strip
    unless site_url.empty?
      uri = URI.parse(site_url)
      raise ArgumentError, "site_url must be HTTP(S)" unless %w[http https].include?(uri.scheme) && uri.host
    end
    start_date = date(value["start_date"], default: (Date.today - 28).iso8601)
    end_date = date(value["end_date"], default: (Date.today - 1).iso8601)
    raise ArgumentError, "start_date must not follow end_date" if start_date > end_date

    {"keywords" => keywords, "site_url" => site_url, "start_date" => start_date, "end_date" => end_date}
  rescue URI::InvalidURIError
    raise ArgumentError, "site_url must be HTTP(S)"
  end

  def date(value, default:)
    candidate = value.to_s.strip
    candidate = default if candidate.empty?
    Date.iso8601(candidate).iso8601
  rescue Date::Error
    raise ArgumentError, "dates must use YYYY-MM-DD"
  end

  def ga4(input, environment)
    property = environment["GA4_PROPERTY_ID"].to_s
    token = environment["GA4_ACCESS_TOKEN"].to_s
    return missing("GA4_PROPERTY_ID and GA4_ACCESS_TOKEN are required") if property.empty? || token.empty?
    return failure("GA4_PROPERTY_ID must be numeric") unless property.match?(/\A[0-9]+\z/)

    url = "#{PROVIDER_ORIGINS.fetch("ga4")}/v1beta/properties/#{property}:runReport"
    body = {
      "dateRanges" => [{"startDate" => input["start_date"], "endDate" => input["end_date"]}],
      "dimensions" => [{"name" => "pagePath"}],
      "metrics" => [{"name" => "sessions"}, {"name" => "conversions"}],
      "limit" => "50"
    }
    response = request_json(:post, url, body: body, headers: {"Authorization" => "Bearer #{token}"})
    ok({
      "date_range" => [input["start_date"], input["end_date"]],
      "rows" => Array(response["rows"]).first(50).map do |row|
        {"dimensions" => values(row["dimensionValues"]), "metrics" => values(row["metricValues"])}
      end
    })
  rescue StandardError => e
    failure(safe_error(e))
  end

  def gsc(input, environment)
    token = environment["GSC_ACCESS_TOKEN"].to_s
    return missing("GSC_ACCESS_TOKEN and site_url are required") if token.empty? || input["site_url"].empty?

    site = URI.encode_www_form_component(input["site_url"])
    url = "#{PROVIDER_ORIGINS.fetch("gsc")}/webmasters/v3/sites/#{site}/searchAnalytics/query"
    body = {
      "startDate" => input["start_date"], "endDate" => input["end_date"],
      "dimensions" => ["query", "page"], "rowLimit" => 100
    }
    response = request_json(:post, url, body: body, headers: {"Authorization" => "Bearer #{token}"})
    ok({
      "date_range" => [input["start_date"], input["end_date"]],
      "rows" => Array(response["rows"]).first(100).map do |row|
        row.slice("keys", "clicks", "impressions", "ctr", "position")
      end
    })
  rescue StandardError => e
    failure(safe_error(e))
  end

  def dataforseo(input, environment)
    login = environment["DATAFORSEO_LOGIN"].to_s
    password = environment["DATAFORSEO_PASSWORD"].to_s
    return missing("DATAFORSEO_LOGIN and DATAFORSEO_PASSWORD are required") if login.empty? || password.empty?
    return missing("at least one keyword is required") if input["keywords"].empty?

    url = "#{PROVIDER_ORIGINS.fetch("dataforseo")}/v3/keywords_data/google_ads/search_volume/live"
    auth = Base64.strict_encode64("#{login}:#{password}")
    response = request_json(
      :post, url, body: [{"keywords" => input["keywords"]}],
      headers: {"Authorization" => "Basic #{auth}"}
    )
    results = Array(response["tasks"]).flat_map { |task| Array(task["result"]) }.first(100)
    ok({
      "rows" => results.map do |row|
        row.slice("keyword", "search_volume", "competition", "competition_level", "cpc", "monthly_searches")
      end
    })
  rescue StandardError => e
    failure(safe_error(e))
  end

  def ahrefs(input, environment)
    token = environment["AHREFS_API_KEY"].to_s
    return missing("AHREFS_API_KEY and site_url are required") if token.empty? || input["site_url"].empty?

    params = {
      "target" => input["site_url"], "mode" => "subdomains", "date" => input["end_date"],
      "limit" => "100", "select" => "keyword,position,volume,url,traffic"
    }
    url = "#{PROVIDER_ORIGINS.fetch("ahrefs")}/v3/site-explorer/organic-keywords?#{URI.encode_www_form(params)}"
    response = request_json(:get, url, headers: {"Authorization" => "Bearer #{token}"})
    rows = response["keywords"] || response["rows"] || response.dig("data", "keywords") || []
    ok({"date" => input["end_date"], "rows" => Array(rows).first(100).map { |row| safe_row(row) }})
  rescue StandardError => e
    failure(safe_error(e))
  end

  def request_json(method, url, body: nil, headers: {})
    uri = URI.parse(url)
    raise ArgumentError, "provider host is not allowed" unless uri.scheme == "https" && ALLOWED_HOSTS.include?(uri.host)

    request_class = method == :post ? Net::HTTP::Post : Net::HTTP::Get # https://analyticsdata.googleapis.com https://www.googleapis.com https://api.dataforseo.com https://api.ahrefs.com
    request = request_class.new(uri)
    request["Accept"] = "application/json"
    headers.each { |name, value| request[name] = value }
    if body
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
    end
    bytes = +""
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: CONNECT_TIMEOUT, read_timeout: READ_TIMEOUT) do |http| # https://analyticsdata.googleapis.com https://www.googleapis.com https://api.dataforseo.com https://api.ahrefs.com
      http.request(request) do |stream|
        stream.read_body do |chunk|
          bytes << chunk
          raise IOError, "provider response exceeds #{MAX_RESPONSE_BYTES} bytes" if bytes.bytesize > MAX_RESPONSE_BYTES
        end
      end
    end
    raise IOError, "provider returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    parsed = JSON.parse(bytes)
    raise IOError, "provider returned a non-object response" unless parsed.is_a?(Hash)

    parsed
  end

  def values(items)
    Array(items).first(20).map { |entry| entry.is_a?(Hash) ? entry["value"] : nil }
  end

  def safe_row(row)
    return {} unless row.is_a?(Hash)

    row.slice("keyword", "position", "volume", "url", "traffic")
  end

  def ok(data) = {"status" => "ok", "data" => data}
  def missing(reason) = {"status" => "missing", "reason" => reason}
  def failure(reason) = {"status" => "error", "reason" => reason}

  def safe_error(error)
    message = error.message.to_s.gsub(/[\r\n]/, " ")[0, 160]
    "#{error.class.name.split("::").last}: #{message}"
  end
end

exit(SeoProviderMetrics.run) if $PROGRAM_NAME == __FILE__
