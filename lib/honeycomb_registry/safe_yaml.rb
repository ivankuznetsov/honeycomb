# frozen_string_literal: true

require "psych"

module HoneycombRegistry
  module SafeYAML
    class Invalid < StandardError
      attr_reader :path, :code

      def initialize(path, code, message)
        @path = path
        @code = code
        super(message)
      end

      def finding
        Finding.new(path: path, code: code, message: message, severity: "error")
      end
    end

    module_function

    def load_file(path)
      load(File.binread(path), path: path.to_s)
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Invalid.new(path.to_s, "yaml.unreadable", e.message)
    end

    def load(bytes, path: "<yaml>")
      source = bytes.dup.force_encoding(Encoding::UTF_8)
      unless source.valid_encoding?
        raise Invalid.new(path, "yaml.invalid_encoding", "YAML must be valid UTF-8")
      end

      stream = Psych.parse_stream(source, filename: path)
      if stream.children.length != 1
        raise Invalid.new(path, "yaml.document_count", "YAML must contain exactly one document")
      end
      document = stream.children.first
      raise Invalid.new(path, "yaml.empty", "YAML document must not be empty") unless document&.root

      inspect_node(document.root, path)
      value = Psych.safe_load(source, permitted_classes: [], permitted_symbols: [],
                                      aliases: false, filename: path, fallback: nil)
      inspect_json_value(value, path)
      value
    rescue Invalid
      raise
    rescue Psych::DisallowedClass => e
      raise Invalid.new(path, "yaml.non_json_value", e.message)
    rescue Psych::Exception => e
      raise Invalid.new(path, "yaml.syntax", e.message.lines.first.to_s.strip)
    end

    def inspect_node(node, path)
      if node.is_a?(Psych::Nodes::Alias)
        raise Invalid.new(path, "yaml.alias", "YAML aliases are not allowed")
      end
      if node.respond_to?(:tag) && node.tag && !node.tag.start_with?("tag:yaml.org,2002:")
        raise Invalid.new(path, "yaml.tag", "custom YAML tags are not allowed")
      end

      case node
      when Psych::Nodes::Mapping
        seen = {}
        node.children.each_slice(2) do |key, value|
          unless key.is_a?(Psych::Nodes::Scalar)
            raise Invalid.new(path, "yaml.non_string_key", "mapping keys must be strings")
          end
          key_path = join_path(path, key.value)
          if seen.key?(key.value)
            raise Invalid.new(key_path, "yaml.duplicate_key", "duplicate mapping key #{key.value.inspect}")
          end
          seen[key.value] = true
          inspect_node(key, key_path)
          inspect_node(value, key_path)
        end
      when Psych::Nodes::Sequence
        node.children.each_with_index { |child, index| inspect_node(child, "#{path}[#{index}]") }
      end
    end

    def inspect_json_value(value, path)
      case value
      when Hash
        value.each do |key, child|
          unless key.is_a?(String)
            raise Invalid.new(path, "yaml.non_string_key", "mapping keys must be strings")
          end
          inspect_json_value(child, join_path(path, key))
        end
      when Array
        value.each_with_index { |child, index| inspect_json_value(child, "#{path}[#{index}]") }
      when String, Integer, TrueClass, FalseClass, NilClass
        nil
      when Float
        unless value.finite?
          raise Invalid.new(path, "yaml.non_json_value", "non-finite numbers are not allowed")
        end
      else
        raise Invalid.new(path, "yaml.non_json_value", "#{value.class} values are not allowed")
      end
    end

    def join_path(path, key)
      key.match?(/\A[a-zA-Z0-9_-]+\z/) ? "#{path}.#{key}" : "#{path}[#{key.inspect}]"
    end
  end
end
