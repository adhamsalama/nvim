-- Lighter LSP on long files: tsgo answers every background request on a 19k-line file in seconds,
-- and they queue up in front of hover/completion. For buffers over `max_lines` (checked when
-- the buffer is first shown):
--   * semantic tokens off (treesitter still highlights)
--   * folds from treesitter instead of LSP foldingRange (and LSP folding kept off)
--   * codelens off (see the lsp_codelens_refresh autocmd in astrolsp.lua)
--   * documentHighlight via words_lite.lua instead of snacks.words (longer debounce,
--     one request in flight, stale replies dropped)
--   * diagnostic pulls debounced, held during insert mode (diag_debounce.lua)
-- Hover, definition and completion are untouched. Flag: `vim.b.lsp_lite`.
-- (Inlay hints are limited to the visible lines on every buffer, see inlay_range.lua.)
-- Wired up in lua/plugins/lsp.lua.

local M = {}

M.max_lines = 2000

function M.is_lite(bufnr)
  if vim.b[bufnr].lsp_lite == nil then vim.b[bufnr].lsp_lite = vim.api.nvim_buf_line_count(bufnr) > M.max_lines end
  return vim.b[bufnr].lsp_lite
end

-- Neovim's LSP folding (vim.lsp.foldexpr) turns itself on with a *scheduled* call the first time
-- the LSP foldexpr is evaluated, and only turns off on an OptionSet of 'foldexpr'. When astroui's
-- LSP-first foldexpr gets evaluated once before the switch to treesitter below, that turn-on can
-- land after the switch and stay on, requesting foldingRange on every edit for nothing. Turning it
-- off for the buffer also keeps a later LspAttach from enabling it. (Private API: pcall.)
local function no_lsp_folds(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.lsp._capability.enable, "folding_range", false, { bufnr = bufnr })
  end
end

function M.setup()
  require("lsp.perf.diag_debounce").setup()
  require("lsp.perf.words_lite").setup { is_lite = M.is_lite }
end

M.autocmds = {
  {
    -- AstroNvim resets the window's foldexpr to astroui's LSP-first one on FileType, which can
    -- fire again after BufWinEnter (lazy-loaded plugins re-trigger it), so apply after both
    event = { "BufWinEnter", "FileType" },
    desc = "Treesitter folds and lite document highlight on long files",
    callback = function(args)
      if vim.bo[args.buf].buftype ~= "" or not M.is_lite(args.buf) then return end
      vim.b[args.buf].snacks_words = false
      vim.schedule(function()
        if vim.api.nvim_get_current_buf() == args.buf then vim.wo[0][0].foldexpr = "v:lua.vim.treesitter.foldexpr()" end
        -- a tick later, after any turn-on the LSP foldexpr scheduled before the switch
        vim.schedule(function() no_lsp_folds(args.buf) end)
      end)
    end,
  },
  {
    event = "LspAttach",
    desc = "No semantic tokens, codelens or LSP folds on long files",
    callback = function(args)
      if not M.is_lite(args.buf) then return end
      -- scheduled so it runs after the client's own attach-time setup
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(args.buf) then return end
        vim.lsp.semantic_tokens.enable(false, { bufnr = args.buf })
        vim.lsp.codelens.enable(false, { bufnr = args.buf })
        no_lsp_folds(args.buf)
      end)
    end,
  },
}

return M
