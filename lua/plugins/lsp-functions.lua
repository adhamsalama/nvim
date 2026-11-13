-- LSP symbol pickers limited to named functions and methods
local kinds = { "Function", "Method" }
local filter = { default = kinds, lua = kinds, markdown = kinds, help = kinds }

-- Skip anonymous functions and callbacks (e.g. tsserver's "describe() callback")
local function named(item)
  local name = vim.trim(item.name or "")
  if name == "" or name:match "^anonymous" or name:match "%(%) callback$" then return false end
end

local function buffer_functions()
  require("snacks").picker.lsp_symbols { title = "Functions/Methods", tree = false, filter = filter, transform = named }
end

local function workspace_functions()
  require("snacks").picker.lsp_workspace_symbols {
    title = "Workspace Functions/Methods",
    filter = filter,
    transform = named,
  }
end

return {
  "AstroNvim/astrocore",
  opts = {
    commands = {
      BufferFunctions = { buffer_functions, desc = "Pick named functions/methods in buffer" },
      WorkspaceFunctions = { workspace_functions, desc = "Pick functions/methods in workspace" },
    },
    mappings = {
      n = {
        ["<Leader>lF"] = { buffer_functions, desc = "LSP Buffer Functions (Named)" },
      },
    },
  },
}
