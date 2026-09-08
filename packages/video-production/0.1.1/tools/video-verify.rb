#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "video-production"

exit HiveVideoProduction::CLI.run(["verify", *ARGV], allowed_commands: ["verify"])
