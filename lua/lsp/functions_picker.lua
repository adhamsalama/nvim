-- LSP symbol pickers limited to named functions and methods

local M = {}

local kinds = { "Function", "Method" }
local filter = { default = kinds, lua = kinds, markdown = kinds, help = kinds }

-- tsgo reports `const f = () => {}` as a Variable and `{ f: async () => {} }` as a Property, so for JS/TS
-- the buffer picker also takes those kinds and keeps the ones whose value is a function (checked with treesitter)
local value_kinds = { Variable = true, Constant = true, Property = true, Field = true }
local js_kinds = vim.list_extend(vim.deepcopy(kinds), vim.tbl_keys(value_kinds))
local buffer_filter = vim.deepcopy(filter)
for _, ft in ipairs { "javascript", "javascriptreact", "typescript", "typescriptreact" } do
  buffer_filter[ft] = js_kinds
end

local fn_types = require("lsp.callhierarchy.common").fn_types
-- nodes that bind a name to a value, keyed by the field holding the value
local binders =
  { variable_declarator = "value", pair = "value", public_field_definition = "value", field_definition = "value" }

-- Skip anonymous functions and callbacks (e.g. tsserver's "describe() callback")
local function named(item)
  local name = vim.trim(item.name or "")
  if name == "" or name:match "^anonymous" or name:match "%(%) callback$" then return false end
end

local function holds_function(buf, item)
  local node =
    vim.treesitter.get_node { bufnr = buf, pos = { item.pos[1] - 1, item.pos[2] }, ignore_injections = false }
  local binder = node and node:parent()
  local field = binder and binders[binder:type()]
  local value = field and binder:field(field)[1]
  return value ~= nil and fn_types[value:type()] == true
end

function M.buffer()
  local buf = vim.api.nvim_get_current_buf()
  local parsed = pcall(function() vim.treesitter.get_parser(buf):parse() end)
  require("snacks").picker.lsp_symbols {
    title = "Functions/Methods",
    tree = false,
    filter = buffer_filter,
    transform = function(item)
      if named(item) == false then return false end
      if value_kinds[item.kind] and not (parsed and holds_function(buf, item)) then return false end
    end,
  }
end

function M.workspace()
  require("snacks").picker.lsp_workspace_symbols {
    title = "Workspace Functions/Methods",
    filter = filter,
    transform = named,
  }
end

return M
