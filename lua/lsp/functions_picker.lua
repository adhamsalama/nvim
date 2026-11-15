-- LSP symbol pickers limited to named functions and methods

local M = {}

local kinds = { "Function", "Method" }
local filter = { default = kinds, lua = kinds, markdown = kinds, help = kinds }

-- Skip anonymous functions and callbacks (e.g. tsserver's "describe() callback")
local function named(item)
  local name = vim.trim(item.name or "")
  if name == "" or name:match "^anonymous" or name:match "%(%) callback$" then return false end
end

function M.buffer()
  require("snacks").picker.lsp_symbols { title = "Functions/Methods", tree = false, filter = filter, transform = named }
end

function M.workspace()
  require("snacks").picker.lsp_workspace_symbols {
    title = "Workspace Functions/Methods",
    filter = filter,
    transform = named,
  }
end

return M
