require 'set'
require 'base64'
require 'tilt/opal'
require 'sprockets'
require 'opal/builder'
require 'opal/sprockets/path_reader'

module Opal
  # Internal: The Processor class is used to make ruby files (with .rb or .opal
  #   extensions) available to any sprockets based server. Processor will then
  #   get passed any ruby source file to build.
  class Processor < TiltTemplate
    @@cache_key = nil
    def self.cache_key
      @@cache_key ||= ['Opal', Opal::VERSION, Opal::Config.config].to_json.freeze
    end

    def self.reset_cache_key!
      @@cache_key = nil
    end

    def evaluate(context, locals, &block)
      return super unless context.is_a? ::Sprockets::Context

      @sprockets = sprockets = context.environment

      # In Sprockets 3 logical_path has an odd behavior when the filename is "index"
      # thus we need to bake our own logical_path
      filename = context.respond_to?(:filename) ? context.filename : context.pathname.to_s
      root_path_regexp = Regexp.escape(context.root_path)
      logical_path = filename.gsub(%r{^#{root_path_regexp}/?(.*?)#{sprockets_extnames_regexp}}, '\1')

      compiler_options = self.compiler_options.merge(file: logical_path)

      compiler = Compiler.new(data, compiler_options)
      result = compiler.compile

      process_requires(compiler.requires, context)
      process_required_trees(compiler.required_trees, context)

      if Opal::Config.source_map_enabled
        map_data = compiler.source_map.as_json
        # Opal 0.11 doesn't fill sourcesContent
        add_sources_content_if_missing(map_data, data)
        "#{result}\n#{to_data_uri_comment(map_data.to_json)}"
      else
        result.to_s
      end
    end

    def self.sprockets_extnames_regexp(sprockets)
      joined_extnames = (['.js']+sprockets.engines.keys).map { |ext| Regexp.escape(ext) }.join('|')
      Regexp.new("(#{joined_extnames})*$")
    end

    def sprockets_extnames_regexp
      @sprockets_extnames_regexp ||= self.class.sprockets_extnames_regexp(@sprockets)
    end

    def process_requires(requires, context)
      requires.each do |required|
        required = required.to_s.sub(sprockets_extnames_regexp, '')
        context.require_asset required unless ::Opal::Config.stubbed_files.include? required
      end
    end

    # Internal: Add files required with `require_tree` as asset dependencies.
    #
    # Mimics (v2) Sprockets::DirectiveProcessor#process_require_tree_directive
    def process_required_trees(required_trees, context)
      return if required_trees.empty?

      # This is the root dir of the logical path, we need this because
      # the compiler gives us the path relative to the file's logical path.
      dirname = File.dirname(file).gsub(/#{Regexp.escape File.dirname(context.logical_path)}#{REGEXP_END}/, '')
      dirname = Pathname(dirname)

      required_trees.each do |original_required_tree|
        required_tree = Pathname(original_required_tree)

        unless required_tree.relative?
          raise ArgumentError, "require_tree argument must be a relative path: #{required_tree.inspect}"
        end

        required_tree = dirname.join(file, '..', required_tree)

        unless required_tree.directory?
          raise ArgumentError, "require_tree argument must be a directory: #{{source: original_required_tree, pathname: required_tree}.inspect}"
        end

        context.depend_on required_tree.to_s

        environment = context.environment

        processor = ::Sprockets::DirectiveProcessor.new
        processor.instance_variable_set('@dirname', File.dirname(file))
        processor.instance_variable_set('@environment', environment)
        path = processor.__send__(:expand_relative_dirname, :require_tree, original_required_tree)
        absolute_paths = environment.__send__(:stat_sorted_tree_with_dependencies, path).first.map(&:first)

        absolute_paths.each do |path|
          path = Pathname(path)
          pathname = path.relative_path_from(dirname).to_s

          if name.to_s == file  then next
          elsif path.directory? then context.depend_on(path.to_s)
          else context.require_asset(pathname)
          end
        end
      end
    end

    # @deprecated
    def self.stubbed_files
      warn "Deprecated: `::Opal::Processor.stubbed_files' is deprecated, use `::Opal::Config.stubbed_files' instead"
      puts caller(5)
      ::Opal::Config.stubbed_files
    end

    # @deprecated
    def self.stub_file(name)
      warn "Deprecated: `::Opal::Processor.stub_file' is deprecated, use `::Opal::Config.stubbed_files << #{name.inspect}.to_s' instead"
      puts caller(5)
      ::Opal::Config.stubbed_files << name.to_s
    end


    private

    def add_sources_content_if_missing(data, content)
      data[:sourcesContent] = data.delete(:sourcesContent) || data.delete('sourcesContent') || [content]
    end

    def to_data_uri_comment(map_to_json)
      "//# sourceMappingURL=data:application/json;base64,#{Base64.encode64(map_to_json).delete("\n")}"
    end

    def stubbed_files
      ::Opal::Config.stubbed_files
    end
  end
end

module Opal::Sprockets::Processor
  module PlainJavaScriptLoader
    def self.call(input)
      sprockets = input[:environment]
      asset = OpenStruct.new(input)

      opal_extnames = sprockets.engines.map do |ext, engine|
        ext if engine <= ::Opal::Processor
      end.compact

      path_extnames     = -> path  { File.basename(path).scan(/\.[^.]+/) }
      processed_by_opal = -> asset { (path_extnames[asset.filename] & opal_extnames).any? }

      if processed_by_opal[asset]
        input[:data]
      else
        "#{input[:data]}\n#{Opal::Sprockets.loaded_asset(input[:name])}"
      end
    end
  end
end

Sprockets.register_engine '.rb',  Opal::Processor, mime_type: 'application/javascript', silence_deprecation: true
Sprockets.register_engine '.opal',  Opal::Processor, mime_type: 'application/javascript', silence_deprecation: true
Sprockets.register_postprocessor 'application/javascript', Opal::Sprockets::Processor::PlainJavaScriptLoader

