-- `grr` / `grR` for tsgo.
--
-- tsgo won't follow a function through an export *object* (`export default { fn }` /
-- `module.exports = { fn }`): asking for references at the function's declaration returns only the
-- shorthand property in that object, not the `Obj.fn()` call sites across files. Asking again *at
-- the shorthand* does resolve them. `follow_references` automates that second hop; `references` is
-- the `grr` handler built on it.

local tsgo = require "lsp.tsgo"

local M = {}

local function key(loc) return ("%s:%d:%d"):format(loc.uri, loc.range.start.line, loc.range.start.character) end

-- A reference that lands on `fn` inside an object literal (`{ fn }`) is the barrier tsgo stops at.
-- Re-request references there to reach the members accessing it (`Obj.fn()`).
local function is_shorthand(loc)
  local ok, _, node = pcall(tsgo.ts_node_at, loc.uri, loc.range.start)
  return ok and node and node:type() == "shorthand_property_identifier" or false
end

-- Starting from `locs`, re-request references at every export shorthand encountered, merging the
-- results, until no new shorthand turns up (re-export chains included). `cb` gets the deduped list.
function M.follow_references(client, locs, cb)
  local seen, result, queue, followed = {}, {}, {}, {}
  local function ingest(list)
    for _, loc in ipairs(list or {}) do
      local k = key(loc)
      if not seen[k] then
        seen[k] = true
        result[#result + 1] = loc
        if not followed[k] and is_shorthand(loc) then queue[#queue + 1] = loc end
      end
    end
  end
  ingest(locs)
  local function step()
    local loc = table.remove(queue, 1)
    if not loc then return cb(result) end
    followed[key(loc)] = true
    local bufnr = tsgo.load_buf(loc.uri)
    tsgo.ensure_attached(client, bufnr)
    client:request("textDocument/references", {
      textDocument = { uri = loc.uri },
      position = loc.range.start,
      context = { includeDeclaration = true },
    }, function(_, more)
      ingest(more)
      step()
    end, bufnr)
  end
  step()
end

local function show(locs, offset_encoding, title)
  if #locs == 0 then return vim.notify("[tsgo] no references found", vim.log.levels.INFO) end
  local items = vim.lsp.util.locations_to_items(locs, offset_encoding)
  vim.fn.setqflist({}, " ", { title = title or "References", items = items })
  vim.cmd "botright copen"
end

local FUNCTION_TYPES = {
  function_declaration = true,
  generator_function_declaration = true,
  function_expression = true,
  ["function"] = true,
  arrow_function = true,
  method_definition = true,
}

-- Is the identifier under the cursor the *name* of a declaration (`const X =`, `function X`,
-- `class X`, method name, ...) rather than a use of it?
local function on_declaration(node)
  local parent = node and node:parent()
  if not parent then return false end
  for _, n in ipairs(parent:field "name") do
    if n:id() == node:id() then return true end
  end
  return false
end

-- Outermost function enclosing `node` (outermost, so a use inside a nested `.map(d => ...)` callback
-- still scopes to the whole named function, not just the callback).
local function outer_function(node)
  local found
  while node do
    if FUNCTION_TYPES[node:type()] then found = node end
    node = node:parent()
  end
  return found
end

local function function_name(fn, bufnr)
  local name = fn:field("name")[1]
  if not name and fn:parent() and fn:parent():type() == "variable_declarator" then
    name = fn:parent():field("name")[1]
  end
  return name and vim.treesitter.get_node_text(name, bufnr) or "function"
end

-- `grr` handler: references for the symbol under the cursor, following export objects on the way, so
-- a function reached only through `import Obj from '...'; Obj.fn()` lists its call sites directly
-- instead of stopping at the export. Falls back to the stock handler when no tsgo client is attached.
--
-- Scoped: on a *use* of a symbol inside a function, only references within that (outermost) function
-- are listed; on the declaration itself, or outside any function, all references. `opts.all` forces
-- the unscoped list (`grR`).
function M.references(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = "tsc" })[1]
  if not client then return vim.lsp.buf.references() end

  local scope
  if not opts.all then
    local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr })
    if ok and node and not on_declaration(node) then scope = outer_function(node) end
  end

  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.context = { includeDeclaration = true }
  client:request("textDocument/references", params, function(err, locs)
    if err then return vim.notify("[tsgo] references: " .. tostring(err.message or err), vim.log.levels.ERROR) end
    if scope then
      local uri = vim.uri_from_bufnr(bufnr)
      local sr, _, er = scope:range()
      local scoped = vim.tbl_filter(function(loc)
        local line = loc.range.start.line
        return loc.uri == uri and line >= sr and line <= er
      end, locs or {})
      return vim.schedule(
        function()
          show(scoped, client.offset_encoding, "References in " .. function_name(scope, bufnr) .. " (grR for all)")
        end
      )
    end
    M.follow_references(client, locs or {}, function(all)
      vim.schedule(function() show(all, client.offset_encoding) end)
    end)
  end, bufnr)
end

return M
