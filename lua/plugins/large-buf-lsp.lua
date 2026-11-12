-- Lighter LSP on long files: tsgo answers every background request on a 19k-line file in seconds,
-- and they queue up in front of hover/completion. For buffers over `max_lines` (checked when
-- the buffer is first shown):
--   * semantic tokens off (treesitter still highlights)
--   * folds from treesitter instead of LSP foldingRange
--   * codelens off (see the lsp_codelens_refresh autocmd in astrolsp.lua)
--   * documentHighlight off (snacks.words, which AstroNvim only gates on its own large_buf limits)
--   * diagnostic pulls debounced, held during insert mode (lua/utils/lsp_diag_debounce.lua)
--   * inlay hints for the visible lines only, one request at a time (lua/utils/lsp_inlay_range.lua)
-- Hover, definition and completion are untouched. Flag: `vim.b.lsp_lite`.

local max_lines = 2000

local function mark(bufnr)
  if vim.b[bufnr].lsp_lite == nil then vim.b[bufnr].lsp_lite = vim.api.nvim_buf_line_count(bufnr) > max_lines end
  return vim.b[bufnr].lsp_lite
end

---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    require("utils.lsp_diag_debounce").setup()
    require("utils.lsp_inlay_range").setup { is_lite = mark }
    opts.autocmds = opts.autocmds or {}
    opts.autocmds.large_buf_lsp = {
      {
        -- AstroNvim resets the window's foldexpr to astroui's LSP-first one on FileType, which can
        -- fire again after BufWinEnter (lazy-loaded plugins re-trigger it), so apply after both
        event = { "BufWinEnter", "FileType" },
        desc = "Treesitter folds and no document highlight on long files",
        callback = function(args)
          if vim.bo[args.buf].buftype ~= "" or not mark(args.buf) then return end
          vim.b[args.buf].snacks_words = false
          vim.schedule(function()
            if vim.api.nvim_get_current_buf() == args.buf then
              vim.wo[0][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
            end
          end)
        end,
      },
      {
        event = "LspAttach",
        desc = "No semantic tokens or codelens on long files",
        callback = function(args)
          if not mark(args.buf) then return end
          -- scheduled so it runs after the client's own attach-time setup
          vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(args.buf) then return end
            vim.lsp.semantic_tokens.enable(false, { bufnr = args.buf })
            vim.lsp.codelens.enable(false, { bufnr = args.buf })
          end)
        end,
      },
    }
  end,
}
