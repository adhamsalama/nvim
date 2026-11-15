-- `<Leader>lN` in tsgo buffers (wired in lua/plugins/lsp.lua).

local M = {}

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

return M
