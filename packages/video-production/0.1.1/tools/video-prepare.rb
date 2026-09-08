#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "video-production"

exit HiveVideoProduction::CLI.run(ARGV, allowed_commands: %w[validate dry-run])
