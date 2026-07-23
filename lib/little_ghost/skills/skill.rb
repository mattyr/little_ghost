# frozen_string_literal: true

module LittleGhost
  module Skills
    Skill = Data.define(:name, :description, :instructions, :path, :allowed_tools, :compatibility)
  end
end
