#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "video-production"

exit HiveVideoProduction::CLI.run(["capture", *ARGV], allowed_commands: ["capture"])
