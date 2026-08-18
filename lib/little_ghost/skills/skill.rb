# frozen_string_literal: true

module LittleGhost
  # Skills give agents focused instructions and supporting resources on demand.
  module Skills
    Skill = Data.define( # :nodoc:
      :name,
      :description,
      :instructions,
      :path,
      :source_path,
      :allowed_tools,
      :compatibility
    )

    # Holds the metadata and instructions loaded from one +SKILL.md+ file.
    # +path+ is shown to the model; +source_path+ is the local file used for
    # boundary validation and resource discovery.
    class Skill < Data # :doc:
      ##
      # :singleton-method: new
      # :call-seq:
      #   new(name:, description:, instructions:, path:, source_path:,
      #       allowed_tools:, compatibility:) -> Skill
      #
      # Collects one validated skill definition loaded by Skills::Catalog.

      ##
      # :attr_reader: name
      # The skill name declared in front matter.

      ##
      # :attr_reader: description
      # The short description used for model-visible discovery.

      ##
      # :attr_reader: instructions
      # The complete instructions loaded on activation.

      ##
      # :attr_reader: path
      # The model-visible skill path.

      ##
      # :attr_reader: source_path
      # The trusted local source path used for boundary checks.

      ##
      # :attr_reader: allowed_tools
      # Informational tool names from front matter; this is not authorization.

      ##
      # :attr_reader: compatibility
      # Optional compatibility guidance from front matter.
    end
  end
end
