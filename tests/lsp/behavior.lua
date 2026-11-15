-- Behavior snapshot: what the custom LSP code *returns*, independent of how it is wired or rendered.
--   * call hierarchy: prepare + incoming/outgoing expanded a few levels, through lspsaga's
--     (overridden) `util.client_request`, exactly as the lspsaga tree requests them
--   * `grr` / `grR` (tsgo references): the quickfix list they produce
--   * reference counts: the virtual lines on a file
-- Children are sorted, since several requests answer in any order. Run via tests/lsp/run.sh.

local H = dofile(debug.getinfo(1, "S").source:sub(2):match "^(.*/)" .. "helpers.lua")

local DEPTH = { ["callHierarchy/incomingCalls"] = 3, ["callHierarchy/outgoingCalls"] = 2 }
local MAX_CHILDREN = 40
local METHODS = { incoming = "callHierarchy/incomingCalls", outgoing = "callHierarchy/outgoingCalls" }

-- module paths moved in the refactor: accept either layout
local function require_any(...)
  for _, name in ipairs { ... } do
    local ok, mod = pcall(require, name)
    if ok then return mod end
  end
  error("none of these modules found: " .. table.concat({ ... }, ", "))
end

local function rng(r)
  return r and ("%d:%d-%d:%d"):format(r.start.line, r.start.character, r["end"].line, r["end"].character)
end
local function pos(p) return p and ("%d:%d"):format(p.line, p.character) end

local function item_line(it)
  local parts = {
    ("%q"):format(it.name or "?"),
    "kind=" .. tostring(it.kind),
    "file=" .. tostring(H.rel(it.uri)),
    "range=" .. tostring(rng(it.range)),
    "sel=" .. tostring(rng(it.selectionRange)),
  }
  local extra = {
    { "decl", rng(it.__decl_range) },
    { "ref_pos", pos(it.__ref_pos) },
    { "orig_name", it.__orig_name },
    { "orig_kind", it.__orig_kind },
    { "var", it.__var },
    { "leaf", it.__ref_leaf },
    { "out_synth", it.__out_synth },
    { "detail", it.detail },
  }
  for _, kv in ipairs(extra) do
    if kv[2] ~= nil then parts[#parts + 1] = kv[1] .. "=" .. tostring(kv[2]) end
  end
  return table.concat(parts, " ")
end

local util

local function request(client, method, params, bufnr)
  local done, err, res = false, nil, nil
  util.client_request(client, method, params, function(e, r)
    err, res, done = e, r, true
  end, bufnr)
  H.wait(180000, function() return done end, method)
  return err, res
end

-- returns the rendered subtree as a list of lines (indented by depth)
local function expand(client, method, item, depth, indent)
  if depth == 0 then return {} end
  local err, res = request(client, method, { item = item })
  if err then return { indent .. "ERROR " .. tostring(err.message or err) } end
  local incoming = method == "callHierarchy/incomingCalls"
  local blocks = {}
  for i, call in ipairs(res or {}) do
    if i > MAX_CHILDREN then
      blocks[#blocks + 1] = { indent .. ("… %d more"):format(#res - MAX_CHILDREN) }
      break
    end
    local it = incoming and call.from or call.to
    local ranges = vim.tbl_map(rng, call.fromRanges or {})
    table.sort(ranges)
    -- render the item before expanding: expansion sends it back and the overrides mutate it in place
    local head = indent .. "- " .. item_line(it) .. " from=[" .. table.concat(ranges, ",") .. "]"
    local block = { head }
    vim.list_extend(block, expand(client, method, it, depth - 1, indent .. "  "))
    blocks[#blocks + 1] = block
  end
  table.sort(blocks, function(a, b) return table.concat(a, "\n") < table.concat(b, "\n") end)
  local lines = {}
  for _, b in ipairs(blocks) do
    vim.list_extend(lines, b)
  end
  return lines
end

local function call_hierarchy(case)
  local bufnr = H.open(case.file)
  local client = H.wait_client(bufnr)
  local p = H.find(bufnr, case.line, case.token, case.nth)
  p.character = p.character + (case.offset or 0)
  if case.col then p.character = case.col end
  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, position = p }
  for _, m in ipairs(case.methods) do
    local method = assert(METHODS[m], "unknown method " .. m)
    H.out(("## %s [%s] at %s:%d:%d"):format(case.name, method:match "/(%a+)Calls$", case.file, p.line, p.character))
    local err, items = request(client, "textDocument/prepareCallHierarchy", vim.deepcopy(params), bufnr)
    if err then
      H.out("prepare ERROR " .. tostring(err.message or err))
    elseif not items or #items == 0 then
      H.out "prepare: (nothing)"
    else
      H.out(("prepare: %d item(s)"):format(#items))
      local root = items[1] -- lspsaga's pick_call_hierarchy_item takes the only one, else asks
      H.out("root " .. item_line(root))
      for _, l in ipairs(expand(client, method, root, DEPTH[method], "  ")) do
        H.out(l)
      end
    end
    H.out ""
  end
end

local function references(case)
  local tsgo = require_any("lsp.tsgo.references", "lsp.tsgo", "utils.tsgo")
  local bufnr = H.open(case.file)
  H.wait_client(bufnr)
  local p = H.find(bufnr, case.line, case.token, case.nth)
  vim.api.nvim_win_set_cursor(0, { p.line + 1, p.character })
  vim.fn.setqflist({}, " ", { title = "__pending__" })
  local notified
  local orig_notify = vim.notify
  vim.notify = function(msg, ...)
    -- only the handler's own messages; others (e.g. the slow-request log) can arrive meanwhile
    if type(msg) == "string" and msg:find "^%[tsgo%]" then notified = msg end
    return orig_notify(msg, ...)
  end
  tsgo.references(case.opts)
  H.wait(180000, function() return notified or vim.fn.getqflist({ title = 1 }).title ~= "__pending__" end, "refs")
  vim.notify = orig_notify
  H.out(("## %s [%s] at %s:%d:%d"):format(case.name, case.opts and "grR" or "grr", case.file, p.line, p.character))
  if notified then
    H.out("notify: " .. notified)
  else
    local qf = vim.fn.getqflist { title = 1, items = 1 }
    H.out("title: " .. qf.title)
    local items = {}
    for _, it in ipairs(qf.items) do
      items[#items + 1] = ("%s:%d:%d %s"):format(vim.fn.bufname(it.bufnr), it.lnum, it.col, vim.trim(it.text))
    end
    table.sort(items)
    for _, l in ipairs(items) do
      H.out("  " .. l)
    end
  end
  vim.cmd "cclose"
  H.out ""
end

local function ref_count(case)
  local rc = require_any("lsp.ref_count", "utils.ref_count")
  local bufnr = H.open(case.file)
  H.wait_client(bufnr)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local ns = vim.api.nvim_create_namespace "lsp_ref_count"
  rc.enable()
  local function marks()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
      local virt = {}
      for _, vl in ipairs(m[4].virt_lines or {}) do
        for _, chunk in ipairs(vl) do
          virt[#virt + 1] = chunk[1]
        end
      end
      out[#out + 1] = ("%d %s"):format(m[2], vim.trim(table.concat(virt)))
    end
    return out
  end
  H.wait(180000, function() return #marks() > 0 end, "ref counts")
  -- settle: counts are swapped in once every request answered; wait for a stable picture
  local prev, stable = nil, 0
  H.wait(60000, function()
    local cur = table.concat(marks(), "\n")
    stable = cur == prev and stable + 1 or 0
    prev = cur
    return stable >= 10
  end, "stable ref counts")
  local final = marks()
  rc.disable()
  H.out(("## %s [ref_count] %s"):format(case.name, case.file))
  for _, l in ipairs(final) do
    H.out("  " .. l)
  end
  H.out ""
end

H.main(function()
  require("lazy").load { plugins = { "lspsaga.nvim" } }
  util = require "lspsaga.util"
  local only = os.getenv "SNAPSHOT_ONLY"
  for _, case in ipairs(H.cases().cases) do
    if not only or case.name:find(only, 1, true) then
      H.log("case: " .. case.name)
      if case.kind == "ch" then
        call_hierarchy(case)
      elseif case.kind == "refs" then
        references(case)
      else
        ref_count(case)
      end
    end
  end
end)
