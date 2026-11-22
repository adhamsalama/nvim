-- LSP folds can go stale: when foldingRange results arrive, Neovim 0.12 (runtime
-- lua/vim/lsp/_folding_range.lua `foldupdate`) only re-evaluates foldexpr in windows of the
-- current tab. Windows elsewhere keep whatever was computed while the LSP had no ranges (e.g. right
-- after the buffer reloaded from disk because Claude or a branch checkout changed it): every line at
-- level 0, no fold markers, `zc` does nothing. After each foldingRange reply, recompute folds in
-- every window showing the buffer (without opening any).
-- Wired up in lua/plugins/lsp.lua.

local M = {}

local astroui_foldexpr = "v:lua.require'astroui.folding'.foldexpr()"

---@param bufnr integer
function M.refresh(bufnr)
  -- foldupdate is a no-op in insert mode; Neovim redoes the current tab's windows on InsertLeave
  if not vim._foldupdate or not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_mode().mode:match "^i" then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    -- long files (`vim.b.lsp_lite`) switch these windows to treesitter folds, skipped by this check
    if vim.wo[win].foldmethod == "expr" and vim.wo[win].foldexpr == astroui_foldexpr then
      vim._foldupdate(win, 0, vim.api.nvim_buf_line_count(bufnr))
    end
  end
end

M.autocmds = {
  {
    event = "LspRequest",
    desc = "Recompute LSP folds in every window of the buffer, not just the current tab's",
    callback = function(args)
      local request = args.data and args.data.request
      if request and request.type == "complete" and request.method == "textDocument/foldingRange" then
        -- scheduled so it runs after the reply's handler has stored the new ranges
        vim.schedule(function() M.refresh(args.buf) end)
      end
    end,
  },
}

return M
