-- `Snacks.picker.lines()` (the <Leader>fl picker) restricted to the function around the cursor.
-- The function is found with treesitter by node type, so it works in any language with a parser.

local M = {}

-- node types that are functions in most grammars (function_declaration, method_definition,
-- arrow_function, function_item, func_literal, lambda_expression, closure_expression, ...)
local FUNC = { "function", "method", "lambda", "closure", "arrow", "constructor", "func_literal" }
-- ...but not their parts or calls (function_call, method_signature, function_type, function_body, ...)
local NOT_FUNC = {
  "call",
  "invocation",
  "parameter",
  "signature",
  "type",
  "body",
  "name",
  "identifier",
  "argument",
  "modifier",
  "keyword",
  "reference",
  "declarator",
}

local function is_function(node)
  local t = node:type()
  for _, w in ipairs(NOT_FUNC) do
    if t:find(w, 1, true) then return false end
  end
  for _, w in ipairs(FUNC) do
    if t:find(w, 1, true) then return true end
  end
  return false
end

-- Outermost multi-line function around the cursor, so nested functions are searched as part of it.
local function outermost_function(bufnr)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, ignore_injections = false })
  if not ok then return end
  local outer
  while node do
    local srow, _, erow = node:range()
    if erow > srow and is_function(node) then outer = node end
    node = node:parent()
  end
  return outer
end

local function function_name(node, bufnr)
  local name = node:field("name")[1]
  if not name and node:parent() then
    -- `const foo = () => {}`, `foo: function () {}`, `local foo = function() end`
    local p = node:parent()
    name = p:field("name")[1] or p:field("key")[1] or p:field("left")[1]
  end
  return name and vim.treesitter.get_node_text(name, bufnr):gsub("%s+", " ") or "anonymous function"
end

function M.pick()
  local bufnr = vim.api.nvim_get_current_buf()
  local node = outermost_function(bufnr)
  if not node then
    vim.notify("No enclosing function, searching the whole buffer", vim.log.levels.INFO)
    return Snacks.picker.lines()
  end
  local srow, _, erow = node:range() -- 0-indexed, inclusive
  local first, last = srow + 1, erow + 1

  Snacks.picker.lines {
    title = ("Lines in %s (%d-%d)"):format(function_name(node, bufnr), first, last),
    finder = function(opts, ctx)
      return vim.tbl_filter(
        function(item) return item.pos[1] >= first and item.pos[1] <= last end,
        require("snacks.picker.source.lines").lines(opts, ctx)
      )
    end,
    -- like the stock `lines` on_show, shifted by the function's first line
    on_show = function(picker)
      local cursor = vim.api.nvim_win_get_cursor(picker.main)
      local info = vim.api.nvim_win_call(picker.main, vim.fn.winsaveview)
      picker.list:view(cursor[1] - first + 1, math.max(info.topline - first + 1, 1))
      picker:show_preview()
    end,
  }
end

return M
