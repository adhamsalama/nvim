-- Shared helpers for working around tsgo (TypeScript 7 native, `tsc --lsp`) quirks.
--
-- tsgo won't follow a function through an export *object* (`export default { fn }` /
-- `module.exports = { fn }`): asking for references at the function's declaration returns only the
-- shorthand property in that object, not the `Obj.fn()` call sites across files. Asking again *at
-- the shorthand* does resolve them. `follow_references` automates that second hop; `references` is
-- the `grr` handler built on it. `lua/plugins/lspsaga.lua` reuses `load_buf`/`ts_node_at`/
-- `ensure_attached` here for the same workaround in its call-hierarchy tree.

local M = {}

-- `bufload()` throws E325 on a file with a swap file (e.g. open in another nvim); these buffers are
-- only read, so skip the swap check for ones not loaded yet.
function M.load_buf(uri)
  local bufnr = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.bo[bufnr].swapfile = false
    vim.fn.bufload(bufnr)
  end
  return bufnr
end

function M.ts_node_at(uri, pos)
  local bufnr = M.load_buf(uri)
  local ft = vim.bo[bufnr].filetype
  if ft == "" then ft = vim.filetype.match { buf = bufnr } or "" end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, vim.treesitter.language.get_lang(ft) or ft)
  if not ok or not parser then return end
  parser:parse()
  return bufnr, vim.treesitter.get_node { bufnr = bufnr, pos = { pos.line, pos.character }, ignore_injections = false }
end

function M.ensure_attached(client, bufnr)
  if vim.lsp.buf_is_attached(bufnr, client.id) then return end
  if vim.bo[bufnr].filetype == "" then vim.bo[bufnr].filetype = vim.filetype.match { buf = bufnr } or "" end
  vim.lsp.buf_attach_client(bufnr, client.id)
end

local function key(loc) return ("%s:%d:%d"):format(loc.uri, loc.range.start.line, loc.range.start.character) end

-- A reference that lands on `fn` inside an object literal (`{ fn }`) is the barrier tsgo stops at.
-- Re-request references there to reach the members accessing it (`Obj.fn()`).
local function is_shorthand(loc)
  local ok, _, node = pcall(M.ts_node_at, loc.uri, loc.range.start)
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
    local bufnr = M.load_buf(loc.uri)
    M.ensure_attached(client, bufnr)
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

-- A built-in Node module's definition is only ever its `@types/node/*.d.ts` stub: the real JS glue
-- that wraps the native C++ bindings (e.g. `lib/zlib.js`, which `require`s the internal binding and
-- exports the public API) ships compiled into the Node binary, not into node_modules, so no LSP can
-- jump to it. `goto_builtin_source` resolves the symbol under the cursor and, when the definition
-- lands in `@types/node`, opens the matching `lib/<module>.js` from the nodejs/node source, pinned to
-- the Node version on PATH so the glue matches what actually runs.
local function node_tag()
  local out = vim.fn.system { "node", "--version" }
  return (vim.v.shell_error == 0 and out:match "v%d+%.%d+%.%d+") or "main"
end

function M.goto_builtin_source()
  local bufnr = vim.api.nvim_get_current_buf()
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = "tsc" })[1]
  if not client then return vim.lsp.buf.definition() end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request("textDocument/definition", params, function(err, result)
    if err then return vim.notify("[tsgo] definition: " .. tostring(err.message or err), vim.log.levels.ERROR) end
    local loc = vim.islist(result) and result[1] or result
    local uri = loc and (loc.uri or loc.targetUri)
    if not uri then return vim.notify("[tsgo] no definition found", vim.log.levels.INFO) end
    -- Match the decoded path, not the raw URI: tsgo percent-encodes `@` as `%40`, so `@types` only
    -- appears after `vim.uri_to_fname`. `@types/node/zlib.d.ts` -> `zlib`; `.../fs/promises.d.ts` ->
    -- `fs/promises`.
    local path = vim.uri_to_fname(uri)
    local mod = path:match "@types[/\\]node[/\\](.-)%.d%.ts$"
    if not mod then
      return vim.notify("[tsgo] not a Node built-in (definition is " .. path .. ")", vim.log.levels.INFO)
    end
    mod = mod:gsub("\\", "/")
    local url = ("https://github.com/nodejs/node/blob/%s/lib/%s.js"):format(node_tag(), mod)
    vim.notify("[tsgo] " .. url, vim.log.levels.INFO)
    vim.ui.open(url)
  end, bufnr)
end

local function show(locs, offset_encoding)
  if #locs == 0 then return vim.notify("[tsgo] no references found", vim.log.levels.INFO) end
  local items = vim.lsp.util.locations_to_items(locs, offset_encoding)
  vim.fn.setqflist({}, " ", { title = "References", items = items })
  vim.cmd "botright copen"
end

-- `grr` handler: references for the symbol under the cursor, following export objects on the way, so
-- a function reached only through `import Obj from '...'; Obj.fn()` lists its call sites directly
-- instead of stopping at the export. Falls back to the stock handler when no tsgo client is attached.
function M.references()
  local bufnr = vim.api.nvim_get_current_buf()
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = "tsc" })[1]
  if not client then return vim.lsp.buf.references() end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.context = { includeDeclaration = true }
  client:request("textDocument/references", params, function(err, locs)
    if err then return vim.notify("[tsgo] references: " .. tostring(err.message or err), vim.log.levels.ERROR) end
    M.follow_references(client, locs or {}, function(all)
      vim.schedule(function() show(all, client.offset_encoding) end)
    end)
  end, bufnr)
end

return M
