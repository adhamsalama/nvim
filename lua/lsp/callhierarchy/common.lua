-- Shared by the call hierarchy overrides (see init.lua).

local tsgo = require "lsp.tsgo"

local M = {}

M.FILE_KINDS, M.FUNCTION_KIND = { [1] = true, [2] = true }, 12 -- File, Module
M.fn_types = { arrow_function = true, function_expression = true, ["function"] = true, generator_function = true }
-- identifiers that get a `__var` root (see prepare.lua) and can name a binding (see names.lua)
M.var_types = {
  identifier = true,
  property_identifier = true,
  shorthand_property_identifier = true,
  shorthand_property_identifier_pattern = true,
}

-- shared with the `grr` override (lua/lsp/tsgo/references.lua) via lua/lsp/tsgo/init.lua
M.load_buf, M.ts_node_at, M.ensure_attached = tsgo.load_buf, tsgo.ts_node_at, tsgo.ensure_attached

-- lspsaga's own `util.client_request`, saved by init.setup() before it is replaced: requests the
-- overrides make themselves go straight to it
M.request = nil

-- file-level entries show the path relative to cwd (absolute if outside it)
function M.rel_path(uri) return vim.fn.fnamemodify(vim.uri_to_fname(uri), ":.") end

function M.text(node, bufnr) return vim.treesitter.get_node_text(node, bufnr) end
function M.lsp_range(node)
  local sr, sc, er, ec = node:range()
  return { start = { line = sr, character = sc }, ["end"] = { line = er, character = ec } }
end

return M
