# frozen_string_literal: true

require "psych"

module HoneycombSecurityLint
  class CommandExtractor
    Command = Struct.new(:path, :line, :column, :kind, :raw, keyword_init: true) do
      def evidence
        {
          "path" => path,
          "line" => line,
          "column" => column,
          "kind" => kind,
          "redacted" => SecretPiiScanner.new.redact_text(raw)
        }
      end
    end

    class Invalid < StandardError; end
    class LimitExceeded < Invalid; end

    COMMAND_START = /\A\s*(?:\$\s*)?(?:(?:bash|sh|zsh|pwsh|powershell|curl|wget|iwr|invoke-webrequest|git|gh|ruby|python\d*|node|npm|npx|bundle|rake|cat|grep|rg|find|ls|head|tail|sed|awk|tar|zip|gzip|base64|openssl|env|printenv|export|set|cp|mv|rm|mkdir|chmod|chown|tee|echo|printf|source)\b|\.\/[^\s]+)(?:\s|[|;&<>()]|\z)/i
    SHELL_FENCE = /\A\s*```\s*(bash|sh|shell|zsh|powershell|pwsh)?\s*\z/i
    YAML_EXTENSION = /\.ya?ml\z/i

    def initialize(max_commands: nil)
      @max_commands = max_commands
    end

    def extract(files, version_root:)
      @command_count = 0
      scoped = files.select { |file| file.text && InstructionScope.include?(file.path, version_root) }
      scoped.flat_map do |file|
        if YAML_EXTENSION.match?(file.path)
          extract_yaml(file)
        else
          extract_markdown(file)
        end
      end.sort_by { |command| [command.path, command.line, command.column, command.kind, command.raw] }
    end

    def command_like?(value)
      value.to_s.match?(COMMAND_START) || value.to_s.match?(/\|\s*(?:sh|bash|zsh|pwsh|powershell)\b/i)
    end

    private

    def extract_markdown(file)
      commands = []
      fence = nil
      file.text.each_line.with_index(1) do |line, line_number|
        stripped = line.chomp
        if (opening = SHELL_FENCE.match(stripped))
          if fence
            fence = nil
          else
            fence = {shell: !opening[1].nil?}
          end
          next
        end
        if fence
          if !stripped.strip.empty? && (fence[:shell] || command_like?(stripped))
            append(commands, build(file.path, line_number, first_column(line), "fenced", stripped))
          end
          next
        end
        if !stripped.strip.empty? && command_like?(stripped)
          append(commands, build(file.path, line_number, first_column(line), "plain", stripped))
        end
        line.to_enum(:scan, /`([^`\r\n]+)`/).each do
          match = Regexp.last_match
          next unless command_like?(match[1])

          append(commands, build(file.path, line_number, match.begin(1) + 1, "inline", match[1]))
        end
      end
      commands
    end

    def extract_yaml(file)
      HoneycombRegistry::SafeYAML.load(file.bytes, path: file.path)
      stream = Psych.parse_stream(file.text, filename: file.path)
      commands = []
      walk_yaml(stream, file.path, commands, mapping_key: false)
      commands
    rescue HoneycombRegistry::SafeYAML::Invalid => e
      raise Invalid, "#{file.path}: #{e.code}: #{e.message}"
    rescue Psych::Exception => e
      raise Invalid, "#{file.path}: malformed YAML: #{e.message.lines.first.to_s.strip}"
    end

    def walk_yaml(node, path, commands, mapping_key:)
      case node
      when Psych::Nodes::Mapping
        node.children.each_slice(2) do |key, value|
          walk_yaml(key, path, commands, mapping_key: true)
          walk_yaml(value, path, commands, mapping_key: false)
        end
      when Psych::Nodes::Sequence, Psych::Nodes::Stream, Psych::Nodes::Document
        node.children.each { |child| walk_yaml(child, path, commands, mapping_key: false) }
      when Psych::Nodes::Scalar
        return if mapping_key || !yaml_string?(node)

        lines = node.value.lines
        if lines.length > 1
          lines.each_with_index do |line, index|
            value = line.chomp
            next if value.strip.empty?

            append(commands, build(path, node.start_line + index + 1, 1, "yaml-string", value))
          end
        else
          append(commands, build(path, node.start_line + 1, node.start_column + 1, "yaml-string", node.value))
        end
      end
    end

    def yaml_string?(node)
      return true if node.quoted || node.style != Psych::Nodes::Scalar::PLAIN
      return false if node.tag && node.tag != "tag:yaml.org,2002:str"

      value = node.value
      !value.match?(/\A(?:null|~|true|false|yes|no|on|off|[-+]?\d+(?:\.\d+)?)\z/i)
    end

    def build(path, line, column, kind, raw)
      Command.new(path: path, line: line, column: column, kind: kind, raw: raw)
    end

    def append(commands, command)
      if @max_commands && @command_count >= @max_commands
        raise LimitExceeded, "extracted command count exceeds policy"
      end
      @command_count += 1
      commands << command
    end

    def first_column(line)
      line.index(/\S/) ? line.index(/\S/) + 1 : 1
    end
  end
end
