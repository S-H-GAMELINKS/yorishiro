# frozen_string_literal: true

module Yorishiro
  # Auto-loads custom skills (slash commands) from skill directories such
  # as ~/.yorishiro/skills and ./.yorishiro/skills. A skill file just
  # defines Yorishiro::Skill subclasses — no registration call needed.
  # New classes are detected by diffing the Skill class tree around the
  # load and registered through Configuration#replace_skill, so the usual
  # validation applies and later directories override same-name skills.
  class SkillLoader
    def initialize(configuration)
      @configuration = configuration
    end

    def load_dir(dir)
      return unless Dir.exist?(dir)

      Dir.glob(File.join(dir, "*.rb")).each { |path| load_file(path) }
    end

    private

    def load_file(path)
      before = skill_classes
      load path
      (skill_classes - before).each { |klass| register(klass, path) }
    rescue ConfigurationError
      raise
    rescue StandardError, SyntaxError => e
      raise ConfigurationError, "Error loading skill file #{path}: #{e.message}"
    end

    def register(klass, path)
      instance = klass.new
      instance.name # abstract intermediate classes raise here — skip them
      @configuration.replace_skill(instance)
    rescue SkillNotImplementedError
      nil
    rescue StandardError => e
      raise ConfigurationError, "Error registering skill #{klass} from #{path}: #{e.message}"
    end

    # Walk the whole subtree so skills inheriting from an intermediate
    # base class (not directly from Skill) are found too.
    def skill_classes
      collect_subclasses(Skill)
    end

    def collect_subclasses(klass)
      klass.subclasses.flat_map { |sub| [sub] + collect_subclasses(sub) }
    end
  end
end
