# frozen_string_literal: true

# Loads LittleGhost's optional Model Context Protocol client. Requiring
# +little_ghost+ alone does not load its HTTP integration.
require_relative "../little_ghost"
require_relative "mcp/client"
require_relative "mcp/toolset"
