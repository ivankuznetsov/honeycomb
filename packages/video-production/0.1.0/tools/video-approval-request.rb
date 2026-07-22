#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "video-production"

exit HiveVideoProduction::CLI.run(["approval-template", *ARGV], allowed_commands: ["approval-template"])
