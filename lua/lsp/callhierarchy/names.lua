-- Treesitter lookups for the call hierarchy overrides: which function or binding encloses a
-- position, and where to point the server at to ask for references to it.

local C = require "lsp.callhierarchy.common"
local load_buf, ts_node_at, text = C.load_buf, C.ts_node_at, C.text
local fn_types, var_types = C.fn_types, C.var_types

local M = {}

local function key_target(name)
  if name and name:type() == "computed_property_name" then name = name:named_child(0) end
  if name and name:type() == "member_expression" then name = name:field("property")[1] end
  return name
end

-- name of the function enclosing `pos`, plus where to ask for references to it.
-- `method_definition` / `function_declaration` carry their own `name`; arrow and function
-- expressions are anonymous, so take the key/name/left of whatever binds them.
local function enclosing_name(uri, pos)
  local bufnr, node = ts_node_at(uri, pos)
  while node do
    local t = node:type()
    local name
    if t == "method_definition" or t == "function_declaration" or t == "method_declaration" then -- last: Go
      name = node:field("name")[1]
    elseif fn_types[t] then
      local parent = node:parent()
      name = parent and (parent:field("key")[1] or parent:field("name")[1] or parent:field("left")[1])
    end
    if name then
      -- for `[KEY]: ...` reference the constant, not the brackets
      local target = key_target(name)
      local row, col = target:start()
      return (vim.treesitter.get_node_text(name, bufnr):gsub("^%[(.*)%]$", "%1")), { line = row, character = col }
    end
    node = node:parent()
  end
end

-- Outside any function, the value a reference is part of: `const X = [ref]`, `X: ref`,
-- `module.exports.X = ref`. Returns the binding's name and its position, so the entry can expand
-- as a variable in turn.
local function enclosing_binding(uri, pos)
  local bufnr, node = ts_node_at(uri, pos)
  local start = node
  while node do
    local t, name = node:type()
    if t == "variable_declarator" or t == "var_spec" or t == "const_spec" then -- last two: Go
      name = node:field("name")[1]
    elseif t == "pair" then
      name = node:field("key")[1]
    elseif t == "assignment_expression" then
      name = node:field("left")[1]
      if name and name:type() == "member_expression" then name = name:field("property")[1] end
    end
    if name then
      name = key_target(name)
      -- the reference must be in the value, not be the binding's own name
      if name and var_types[name:type()] and not (start == name or vim.treesitter.is_ancestor(name, start)) then
        local row, col = name:start()
        return text(name, bufnr), { line = row, character = col }
      end
      return
    end
    node = node:parent()
  end
end

-- tsserver only prepares a call hierarchy with the cursor exactly on the function's name. With it
-- elsewhere on the declaration line (`async`, the indent, the parameters), point at the name.
local function declaration_name_pos(params)
  local bufnr = load_buf(params.textDocument.uri)
  local pos = vim.deepcopy(params.position)
  local line = vim.api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1] or ""
  pos.character = math.max(pos.character, #line:match "^%s*")
  local _, node = ts_node_at(params.textDocument.uri, pos)
  while node do
    local t, name, fn = node:type()
    if t == "method_definition" or t == "function_declaration" then
      name, fn = node:field("name")[1], node
    elseif t == "pair" or t == "variable_declarator" then
      local value = node:field("value")[1]
      if value and fn_types[value:type()] then
        name, fn = node:field("key")[1] or node:field("name")[1], value
      end
    end
    if name then
      local body = fn:field("body")[1]
      local br, bc = (body or fn):start()
      if pos.line > br or (pos.line == br and pos.character >= bc) then return end
      local target = key_target(name)
      local row, col = target:start()
      return { line = row, character = col }
    end
    node = node:parent()
  end
end

M.key_target = key_target
M.enclosing_name = enclosing_name
M.enclosing_binding = enclosing_binding
M.declaration_name_pos = declaration_name_pos

return M
