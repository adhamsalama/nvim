-- Shared helpers for working around tsgo (TypeScript 7 native, `tsc --lsp`) quirks: loading and
-- parsing files that aren't open, and attaching the client to them so it answers requests there.
-- Used by the `grr` handler (references.lua) and the call hierarchy overrides (lua/lsp/callhierarchy).

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

-- innermost node at `pos`, inside injections (Rust macro arguments are reparsed as Rust, so a call
-- there is still a call) unless `host` is set
function M.ts_node_at(uri, pos, host)
  local bufnr = M.load_buf(uri)
  local ft = vim.bo[bufnr].filetype
  if ft == "" then ft = vim.filetype.match { buf = bufnr } or "" end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, vim.treesitter.language.get_lang(ft) or ft)
  if not ok or not parser then return end
  parser:parse()
  return bufnr,
    vim.treesitter.get_node { bufnr = bufnr, pos = { pos.line, pos.character }, ignore_injections = host == true }
end

function M.ensure_attached(client, bufnr)
  if vim.lsp.buf_is_attached(bufnr, client.id) then return end
  if vim.bo[bufnr].filetype == "" then vim.bo[bufnr].filetype = vim.filetype.match { buf = bufnr } or "" end
  vim.lsp.buf_attach_client(bufnr, client.id)
end

return M
