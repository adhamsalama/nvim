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
  "table_constructor", -- Lua's `{}`
  "index", -- Lua's `obj:method` in a call (method_index_expression)
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

-- A function passed to a call (a callback, closure or lambda argument) is part of the function it's written in.
local CALL_ARG = { "argument", "call_suffix", "annotated_lambda" }
-- What a function's own lines can extend to (`const f = ...;`, `export ...`, a pair, decorators), but not past these.
local CONTAINER = {
  "program",
  "source_file",
  "chunk",
  "translation_unit",
  "block",
  "body",
  "statement_list", -- Go
  "statements", -- Kotlin, Swift
  "class",
  "object",
  "table_constructor",
  "array",
  "dictionary",
  "argument",
  "declaration_list",
}
local function type_has(node, words)
  local t = node:type()
  for _, w in ipairs(words) do
    if t:find(w, 1, true) then return true end
  end
  return false
end

local function is_call_arg(node)
  local parent = node:parent()
  while parent and parent:type():find("parenthesized", 1, true) do
    parent = parent:parent()
  end
  return parent ~= nil and type_has(parent, CALL_ARG)
end

---A function and the nodes of the declaration it's written in (`const f = () => {}`, `export`, a pair, decorators):
---the parents ending on its last row, up to a container. Innermost first.
---@return TSNode[]
local function declaration_nodes(fn)
  local nodes = { fn }
  local _, _, erow = fn:range()
  local parent = fn:parent()
  while parent and not type_has(parent, CONTAINER) do
    local psrow, _, perow, pecol = parent:range()
    if pecol == 0 and perow > psrow then perow = perow - 1 end -- ending at column 0 is ending on the row before
    if perow ~= erow then break end
    table.insert(nodes, parent)
    parent = parent:parent()
  end
  return nodes
end

---Rows of a function with the declaration it's written in.
---@return integer srow, integer erow 0-indexed, inclusive
local function declaration_rows(fn)
  local srow, _, erow = fn:range()
  for _, node in ipairs(declaration_nodes(fn)) do
    srow = math.min(srow, (node:range()))
  end
  return srow, erow
end

-- Fields that name a function, on its node or its declaration: a function's or method's name, a variable
-- (`const f = ...`, Go's `f := ...`, Rust's `let f = ...`), an object key, an assignment's target, a class field, a C
-- declarator.
local NAME_FIELDS = { "name", "key", "left", "property", "pattern", "declarator" }
-- Words a declaration's first line starts with, dropped when the name comes from that line
local KEYWORDS = {
  "export",
  "default",
  "async",
  "local",
  "const",
  "let",
  "var",
  "function",
  "def",
  "func",
  "fn",
  "pub",
  "static",
  "public",
  "private",
  "protected",
  "override",
  "final",
  "abstract",
}

---The name of a function: from its node or its declaration's, else its declaration's first line (`M.run = function`).
---@param fn TSNode
---@param bufnr integer
---@return string
local function function_name(fn, bufnr)
  local nodes = declaration_nodes(fn)
  for _, node in ipairs(nodes) do
    for _, field in ipairs(NAME_FIELDS) do
      local name = node:field(field)[1]
      if name then
        local text = vim.treesitter.get_node_text(name, bufnr):gsub("%s+", " "):match "^[^(]*" -- C: `foo(int x)`
        if vim.trim(text) ~= "" then return vim.trim(text) end
      end
    end
  end
  local srow = select(1, nodes[#nodes]:range())
  local line = vim.trim(vim.api.nvim_buf_get_lines(bufnr, srow, srow + 1, false)[1] or "")
  local words = vim.split(line:match "^[^=({:]*" or line, "%s+", { trimempty = true })
  while words[1] and vim.tbl_contains(KEYWORDS, words[1]) do
    table.remove(words, 1)
  end
  return #words > 0 and table.concat(words, " ") or "anonymous function"
end

---Every function, method and function variable in the buffer, as <Leader>af finds them: not callbacks (a function
---passed to a call is part of the function it's written in), with the lines of the declaration each is written in.
---@param bufnr integer?
---@return { name: string, first: integer, last: integer }[] first, last: 1-indexed, inclusive; in buffer order
function M.functions(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return {} end
  local tree = parser:parse()[1]
  if not tree then return {} end
  local found = {}
  local function walk(node)
    if node:named() and is_function(node) and not is_call_arg(node) then -- not keyword tokens (`function`)
      local srow, erow = declaration_rows(node)
      table.insert(found, { name = function_name(node, bufnr), first = srow + 1, last = erow + 1 })
    end
    for child in node:iter_children() do
      walk(child)
    end
  end
  walk(tree:root())
  return found
end

---The first function (outermost first) in `node`, that isn't a call argument unless `any`, and whose declaration
---holds `row`.
local function function_in(node, row, any)
  if is_function(node) and (any or not is_call_arg(node)) then
    local srow, erow = declaration_rows(node)
    if row >= srow and row <= erow then return node end
  end
  for child in node:iter_children() do
    local found = function_in(child, row, any)
    if found then return found end
  end
end

---Lines of the function, method or function variable around the cursor, with the declaration it's written in. Inside
---a callback (a function passed to a call), the function the callback is written in.
---@param bufnr integer?
---@return integer? first, integer? last 1-indexed, inclusive
function M.range(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, ignore_injections = false })
  if not ok or not node then return end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1

  -- On a function's declaration but outside the function's own node (`const`, its name, `export`, a decorator): the
  -- statement the cursor is in holds it.
  local stmt = node
  while not is_function(stmt) and stmt:parent() and not type_has(stmt:parent(), CONTAINER) do
    stmt = stmt:parent()
  end
  local fn = not is_function(stmt) and function_in(stmt, row, false)

  if not fn then
    local innermost
    while node do
      if is_function(node) then
        innermost = innermost or node
        if not is_call_arg(node) then
          fn = node
          break
        end
      end
      node = node:parent()
    end
    fn = fn or innermost or function_in(stmt, row, true)
  end
  if not fn then return end
  local srow, erow = declaration_rows(fn)
  return srow + 1, erow + 1
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
