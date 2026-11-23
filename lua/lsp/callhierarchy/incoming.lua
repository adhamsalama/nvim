-- Incoming "calls" built from `textDocument/references`, for what tsgo has no call hierarchy for:
-- functions only passed around, functions in object properties, and variables.

local C = require "lsp.callhierarchy.common"
local names = require "lsp.callhierarchy.names"
local load_buf, ts_node_at, ensure_attached = C.load_buf, C.ts_node_at, C.ensure_attached
local text, rel_path, FUNCTION_KIND = C.text, C.rel_path, C.FUNCTION_KIND
local enclosing_name, enclosing_binding = names.enclosing_name, names.enclosing_binding
local function orig_request(...) return C.request(...) end

local M = {}

local call_types = { call_expression = true, call = true } -- JS/Go, Python
local args_types = { arguments = true, argument_list = true } -- JS, Go/Python

local function reference_entry(loc)
  local bufnr, node = ts_node_at(loc.uri, loc.range.start)
  local parent = node and node:parent()
  if not parent then return end
  local access = (parent:type() == "member_expression" and parent:field("property")[1] == node)
    or (parent:type() == "selector_expression" and parent:field("field")[1] == node) -- Go `x.Method`
    or (parent:type() == "attribute" and parent:field("attribute")[1] == node) -- Python `x.method`
    or (parent:type() == "field_expression" and parent:field("field")[1] == node) -- Rust `x.method`
    or (parent:type() == "scoped_identifier" and parent:field("name")[1] == node) -- Rust `Type::f`
    or (parent:type() == "subscript_expression" and parent:field("index")[1] == node)
  local outer_sub = access and parent:parent()
  if outer_sub and outer_sub:type() == "subscript_expression" and outer_sub:field("index")[1] == parent then
    parent = outer_sub
  end
  local callee = access and parent or node
  local call = callee:parent()
  local entry = { kind = FUNCTION_KIND, uri = loc.uri, range = loc.range, selectionRange = loc.range }

  if call and call_types[call:type()] and call:field("function")[1] == callee then
    local name, ref_pos = enclosing_name(loc.uri, loc.range.start)
    entry.name = name or ("%s:%d"):format(rel_path(loc.uri), loc.range.start.line + 1)
    entry.__ref_pos, entry.__ref_leaf = ref_pos, not ref_pos or nil
    return entry
  end
  local passed = not access and args_types[parent:type()]
  if not (access or passed) then return end

  local object = passed and text(node, bufnr)
    or text(
      parent:field("object")[1] or parent:field("operand")[1] or parent:field("value")[1] or parent:field("path")[1],
      bufnr
    )
  local outer
  for n in function(_, cur) return cur:parent() end, nil, node do
    if args_types[n:type()] and n:parent() and call_types[n:parent():type()] then outer = n end
  end
  if passed and not outer then return end -- `new X(fn)` and the like
  if outer then
    local first = outer:named_child(0)
    local arg = first and first:type() == "string" and text(first, bufnr) or ""
    entry.name = ("%s(%s) · %s"):format(text(outer:parent():field("function")[1], bufnr), arg, object)
  elseif not passed then
    entry.name = parent:type() == "subscript_expression" and ("%s[…]"):format(object) or text(parent, bufnr)
  end
  entry.__ref_leaf = true
  return entry
end

-- tsgo doesn't follow CommonJS exports across files: references to a function exported as
-- `module.exports = { fn }` stop at that shorthand. Find the files importing it by name
-- (`const { fn } = require(...)` / `import { fn }`), keep the imports that resolve to one of
-- `exports`, and return the references found from there.
local import_types = { shorthand_property_identifier_pattern = true, import_specifier = true }
local function importer_references(client, name, exports, cb)
  local rg = vim
    .system({ "rg", "--vimgrep", "-wF", "--glob", "!node_modules", "--type", "js", "--type", "ts", name, "." }, {
      text = true,
    })
    :wait()
  local cands = {}
  for line in vim.gsplit(rg.stdout or "", "\n", { trimempty = true }) do
    local file, lnum, col = line:match "^(.-):(%d+):(%d+):"
    if file then
      local uri = vim.uri_from_fname(vim.fn.fnamemodify(file, ":p"))
      local pos = { line = tonumber(lnum) - 1, character = tonumber(col) - 1 }
      local ok, bufnr, node = pcall(ts_node_at, uri, pos)
      if ok and node and (import_types[node:type()] or import_types[node:parent() and node:parent():type() or ""]) then
        cands[#cands + 1] = { uri = uri, pos = pos, bufnr = bufnr }
      end
    end
  end
  local out, pending = {}, #cands
  if pending == 0 then
    return vim.schedule(function() cb(out) end)
  end
  local function done()
    pending = pending - 1
    if pending == 0 then cb(out) end
  end
  for _, cand in ipairs(cands) do
    ensure_attached(client, cand.bufnr)
    local params = { textDocument = { uri = cand.uri }, position = cand.pos }
    orig_request(client, "textDocument/definition", params, function(_, res)
      local hit = false
      for _, d in ipairs(res and (res.uri or res.targetUri) and { res } or res or {}) do
        local r = d.targetSelectionRange or d.range
        hit = hit or exports[("%s:%d:%d"):format(d.targetUri or d.uri, r.start.line, r.start.character)]
      end
      if not hit then return done() end
      params.context = { includeDeclaration = false }
      orig_request(client, "textDocument/references", params, function(_, locs)
        vim.list_extend(out, locs or {})
        done()
      end, cand.bufnr)
    end, cand.bufnr)
  end
end

local function request_references(client, item, handler)
  local params = {
    textDocument = { uri = item.uri },
    position = item.__ref_pos,
    context = { includeDeclaration = false },
  }
  return orig_request(client, "textDocument/references", params, function(err, locs, ...)
    local calls, exports, name, seen = {}, {}, nil, {}
    local function key(loc) return ("%s:%d:%d"):format(loc.uri, loc.range.start.line, loc.range.start.character) end
    -- `follow` is set only on the server's own results: a shorthand there (`export default { fn }`
    -- / `module.exports = { fn }`) is the barrier tsgo stops references at, not a call, so record
    -- it and chase through it rather than listing it. `seen` keeps the re-requests below from
    -- re-adding the shorthand or double-counting a site two of them both return.
    local function add(list, follow)
      for _, loc in ipairs(list) do
        if not seen[key(loc)] then
          seen[key(loc)] = true
          local ok, bufnr, node = pcall(ts_node_at, loc.uri, loc.range.start)
          if follow and ok and node and node:type() == "shorthand_property_identifier" then
            exports[key(loc)] = loc
            name = text(node, bufnr)
          else
            local ok2, entry = pcall(reference_entry, loc)
            if ok2 and entry then calls[#calls + 1] = { from = entry, fromRanges = { loc.range } } end
          end
        end
      end
    end
    add(locs or {}, true)
    if not name then return handler(err, calls, ...) end
    local rest = { ... }

    -- Callers reach a function parked in an export object two ways, and the query on its
    -- declaration follows neither:
    --   * `import Obj from '...'; Obj.fn()` — tsgo *does* resolve these, but only when references
    --     are requested at the property inside the export object, so ask there.
    --   * `const { fn } = require('...')` / `import { fn }` — named, so `importer_references`
    --     finds the importing files and asks from each.
    local pending = 1
    local function finish()
      pending = pending - 1
      if pending == 0 then handler(err, calls, unpack(rest)) end
    end
    for _, loc in pairs(exports) do
      pending = pending + 1
      local bufnr = load_buf(loc.uri)
      ensure_attached(client, bufnr)
      orig_request(client, "textDocument/references", {
        textDocument = { uri = loc.uri },
        position = loc.range.start,
        context = { includeDeclaration = false },
      }, function(_, more)
        add(more or {}, false)
        finish()
      end, bufnr)
    end
    importer_references(client, name, exports, function(more)
      add(more, false)
      finish()
    end)
  end)
end

-- Incoming "calls" of a `__var` root: its references, grouped by the named function each sits in
-- (anonymous callbacks are walked through to the named one). Each function entry expands to its
-- own callers via `request_references`; top-level uses become leaves named `path:line`.
local function request_var_references(client, item, handler)
  local params = {
    textDocument = { uri = item.uri },
    position = item.__ref_pos,
    context = { includeDeclaration = false },
  }
  return orig_request(client, "textDocument/references", params, function(err, locs, ...)
    local calls, by_fn = {}, {}
    for _, loc in ipairs(locs or {}) do
      local ok, name, ref_pos = pcall(enclosing_name, loc.uri, loc.range.start)
      local is_var = false
      if not (ok and name and ref_pos) then
        ok, name, ref_pos = pcall(enclosing_binding, loc.uri, loc.range.start)
        is_var = true
      end
      local key = ok and name and ref_pos and ("%s:%d:%d"):format(loc.uri, ref_pos.line, ref_pos.character)
      if key and by_fn[key] then
        table.insert(by_fn[key].fromRanges, loc.range)
      else
        local entry = { kind = FUNCTION_KIND, uri = loc.uri, range = loc.range, selectionRange = loc.range }
        if key then
          entry.name, entry.__ref_pos = name, ref_pos
          if is_var then
            entry.kind, entry.__var = 13, true -- Variable: expands to where *it* is used
          end
        else
          entry.name, entry.__ref_leaf = ("%s:%d"):format(rel_path(loc.uri), loc.range.start.line + 1), true
        end
        local call = { from = entry, fromRanges = { loc.range } }
        calls[#calls + 1] = call
        if key then by_fn[key] = call end
      end
    end
    handler(err, calls, ...)
  end)
end

M.request_references = request_references
M.request_var_references = request_var_references

return M
