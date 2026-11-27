-- The statusline: AstroNvim's default list, plus a whitespace indicator in Diffview (ignored or shown, toggled with
-- <leader>gw, lua/plugins/diffview.lua) and an LSP "waiting for reply" spinner (see
-- `lua/lsp/perf/pending.lua`) just left of the LSP client names. This replaces the whole list, so other specs can't
-- add to it: entries go here.

---@type LazySpec
return {
  "rebelot/heirline.nvim",
  opts = function(_, opts)
    local status = require "astroui.status"
    local pending = require "lsp.perf.pending"
    pending.setup()

    opts.statusline = {
      hl = { fg = "fg", bg = "bg" },
      status.component.mode(),
      status.component.git_branch(),
      status.component.file_info(),
      status.component.git_diff(),
      status.component.diagnostics(),
      { -- in Diffview windows (diff buffers and its panels): whether whitespace changes are ignored
        condition = function() return vim.wo.diff or vim.bo.filetype:match "^Diffview" ~= nil end,
        init = function(self) self.ignored = vim.tbl_contains(vim.opt.diffopt:get(), "iwhiteall") end,
        provider = function(self) return self.ignored and " 󱁐 whitespace ignored " or " 󱁐 whitespace shown " end,
        hl = function(self) return { fg = "bg", bg = self.ignored and "diag_WARN" or "diag_INFO", bold = true } end,
      },
      status.component.fill(),
      status.component.cmd_info(),
      status.component.fill(),
      {
        provider = function() return pending.status(vim.api.nvim_get_current_buf()) .. " " end,
        condition = function() return pending.pending(vim.api.nvim_get_current_buf()) ~= nil end,
        hl = { fg = "fg" },
      },
      status.component.lsp(),
      status.component.virtual_env(),
      status.component.treesitter(),
      status.component.nav(),
      status.component.mode { surround = { separator = "right" } },
    }
  end,
}
