-- tsserver has no call hierarchy item for a function stored in an object property
-- (`name: async () => {}` / `name: function () {}`), so prepare returns nothing. With the
-- cursor on such a name, build the root item here and let references drive the expansion.
--
-- Any other identifier (a variable, constant, property) has no call hierarchy at all, so the root
-- becomes a `__var` item: its "incoming calls" are the functions it's referenced in.

local C = require "lsp.callhierarchy.common"
local key_target = require("lsp.callhierarchy.names").key_target
local ts_node_at, text, lsp_range = C.ts_node_at, C.text, C.lsp_range
local fn_types, var_types, FUNCTION_KIND = C.fn_types, C.var_types, C.FUNCTION_KIND

local M = {}

local function var_fallback(uri, bufnr, node)
  if not (node and var_types[node:type()]) then return end
  local row, col = node:start()
  return {
    name = text(node, bufnr),
    kind = 13, -- Variable
    uri = uri,
    range = lsp_range(node),
    selectionRange = lsp_range(node),
    __ref_pos = { line = row, character = col },
    __var = true,
  }
end

local function prepare_fallback(params)
  local uri = params.textDocument.uri
  local bufnr, node = ts_node_at(uri, params.position)
  local start = node
  for _ = 1, 3 do
    if not node then break end
    local parent = node:parent()
    if parent and parent:type() == "pair" and parent:field("key")[1] == node then
      local value = parent:field("value")[1]
      if not (value and fn_types[value:type()]) then break end
      local target = key_target(node)
      local row, col = target:start()
      return {
        name = (text(node, bufnr):gsub("^%[(.*)%]$", "%1")),
        kind = FUNCTION_KIND,
        uri = uri,
        range = lsp_range(parent),
        selectionRange = lsp_range(node),
        __ref_pos = { line = row, character = col },
      }
    end
    node = parent
  end
  return var_fallback(uri, bufnr, start)
end

M.prepare_fallback = prepare_fallback

return M
