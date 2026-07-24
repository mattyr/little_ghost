# frozen_string_literal: true

module LittleGhost
  module Skills
    Skill = Data.define(
      :name,
      :description,
      :instructions,
      :path,
      :source_path,
      :allowed_tools,
      :compatibility
    )
  end
end
