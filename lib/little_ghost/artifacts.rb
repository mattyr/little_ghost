# frozen_string_literal: true

module LittleGhost
  # Artifacts keep complete Tool results and input attachments outside the model
  # conversation while returning stable, bounded references to agents.
  module Artifacts
  end
end

require_relative "artifacts/workspace_store"
require_relative "artifacts/presentation_budget"
