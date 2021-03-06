# frozen_string_literal: true
begin
  require "bundler"
rescue LoadError
end

module Licensed
  module Source
    class Bundler
      GEMFILES = %w{Gemfile gems.rb}.freeze
      DEFAULT_WITHOUT_GROUPS = %i{development test}

      def self.type
        "rubygem"
      end

      def initialize(config)
        @config = config
      end

      def enabled?
        defined?(::Bundler) && lockfile_path && lockfile_path.exist?
      end

      def dependencies
        @dependencies ||= with_local_configuration do
          specs.map do |spec|
            Licensed::Dependency.new(spec.gem_dir, {
              "type"     => Bundler.type,
              "name"     => spec.name,
              "version"  => spec.version.to_s,
              "summary"  => spec.summary,
              "homepage" => spec.homepage
            })
          end
        end
      end

      # Returns an array of Gem::Specifications for all gem dependencies
      def specs
        # get the specifications for all dependencies in a Gemfile
        root_dependencies = definition.dependencies.select { |d| include?(d, nil) }
        root_specs = specs_for_dependencies(root_dependencies, nil).compact

        # recursively find the remaining specifications
        all_specs = recursive_specs(root_specs)

        # delete any specifications loaded from a gemspec
        all_specs.delete_if { |s| s.source.is_a?(::Bundler::Source::Gemspec) }
      end

      # Recursively finds the dependencies for Gem specifications.
      # Returns a `Set` containing the package names for all dependencies
      def recursive_specs(specs, results = Set.new)
        return [] if specs.nil? || specs.empty?

        new_specs = Set.new(specs) - results.to_a
        return [] if new_specs.empty?

        results.merge new_specs

        dependency_specs = new_specs.flat_map { |s| specs_for_dependencies(s.dependencies, s.source) }

        return results if dependency_specs.empty?

        results.merge recursive_specs(dependency_specs, results)
      end

      # Returns the specs for dependencies that pass the checks in `include?`
      # Raises an error if the specification isn't found
      def specs_for_dependencies(dependencies, source)
        included_dependencies = dependencies.select { |d| include?(d, source) }
        included_dependencies.map do |dep|
          gem_spec(dep) || raise("Unable to find a specification for #{dep.name} (#{dep.requirement}) in any sources")
        end
      end

      # Returns a Gem::Specification for the provided gem argument.  If a
      # Gem::Specification isn't found, an error will be raised.
      def gem_spec(dependency)
        return unless dependency

        # bundler specifications aren't put in ::Bundler.specs_path, even if the
        # gem is a runtime dependency.  it needs to be handled specially
        return bundler_spec if dependency.name == "bundler"

        # find a specifiction from the resolved ::Bundler::Definition specs
        spec = definition.resolve.find { |s| s.satisfies?(dependency) }
        return spec unless spec.is_a?(::Bundler::LazySpecification)

        # if the specification is coming from a gemspec source,
        # we can get a non-lazy specification straight from the source
        if spec.source.is_a?(::Bundler::Source::Gemspec)
          return spec.source.specs.first
        end

        # look for a specification at the bundler specs path
        spec_path = ::Bundler.specs_path.join("#{spec.full_name}.gemspec")
        return unless File.exist?(spec_path.to_s)
        Gem::Specification.load(spec_path.to_s)
      end

      # Returns whether a dependency should be included in the final
      def include?(dependency, source)
        # ::Bundler::Dependency has an extra `should_include?`
        return false unless dependency.should_include? if dependency.respond_to?(:should_include?)

        # Don't return gems added from `add_development_dependency` in a gemspec
        # if the :development group is excluded
        gemspec_source = source.is_a?(::Bundler::Source::Gemspec)
        return false if dependency.type == :development && (!gemspec_source || exclude_development_dependencies?)

        # Gem::Dependency don't have groups - in our usage these objects always
        # come as child-dependencies and are never directly from a Gemfile.
        # We assume that all Gem::Dependencies are ok at this point
        return true if dependency.groups.nil?

        # check if the dependency is in any groups we're interested in
        (dependency.groups & groups).any?
      end

      # Returns whether development dependencies should be excluded
      def exclude_development_dependencies?
        @include_development ||= begin
          # check whether the development dependency group is explicitly removed
          # or added via bundler and licensed configurations
          groups = [:development] - Array(::Bundler.settings[:without]) + Array(::Bundler.settings[:with]) - exclude_groups
          !groups.include?(:development)
        end
      end

      # Returns a gemspec for bundler, found and loaded by running `gem specification bundler`
      # This is a hack to work around bundler not placing it's own spec at
      # `::Bundler.specs_path` when it's an explicit dependency
      def bundler_spec
        # cache this so we run CLI commands as few times as possible
        return @bundler_spec if defined?(@bundler_spec)

        # finding the bundler gem is dependent on having `gem` available
        unless Licensed::Shell.tool_available?("gem")
          @bundler_spec = nil
          return
        end

        # Bundler is always used from the default gem install location.
        # we can use `gem specification bundler` with a clean ENV to
        # get the system bundler gem as YAML
        yaml = ::Bundler.with_original_env { Licensed::Shell.execute("gem", "specification", "bundler") }
        @bundler_spec = Gem::Specification.from_yaml(yaml)
      end

      # Build the bundler definition
      def definition
        @definition ||= ::Bundler::Definition.build(gemfile_path, lockfile_path, nil)
      end

      # Returns the bundle definition groups, removing "without" groups,
      # and including "with" groups
      def groups
        definition.groups - Array(::Bundler.settings[:without]) + Array(::Bundler.settings[:with]) - exclude_groups
      end

      # Returns any groups to exclude specified from both licensed configuration
      # and bundler configuration.
      # Defaults to [:development, :test] + ::Bundler.settings[:without]
      def exclude_groups
        @exclude_groups ||= begin
          exclude = Array(@config.dig("rubygems", "without"))
          exclude.push(*DEFAULT_WITHOUT_GROUPS) if exclude.empty?
          exclude.uniq.map(&:to_sym)
        end
      end

      # Returns the path to the Bundler Gemfile
      def gemfile_path
        @gemfile_path ||= GEMFILES.map { |g| @config.pwd.join g }
                                  .find { |f| f.exist? }
      end

      # Returns the path to the Bundler Gemfile.lock
      def lockfile_path
        return unless gemfile_path
        @lockfile_path ||= gemfile_path.dirname.join("#{gemfile_path.basename}.lock")
      end

      private

      # helper to clear all bundler environment around a yielded block
      def with_local_configuration
        # force bundler to use the local gem file
        original_bundle_gemfile, ENV["BUNDLE_GEMFILE"] = ENV["BUNDLE_GEMFILE"], gemfile_path.to_s

        # reset all bundler configuration
        ::Bundler.reset!
        # and re-configure with settings for current directory
        ::Bundler.configure

        yield
      ensure
        ENV["BUNDLE_GEMFILE"] = original_bundle_gemfile
        # restore bundler configuration
        ::Bundler.reset!
        ::Bundler.configure
      end
    end
  end
end
