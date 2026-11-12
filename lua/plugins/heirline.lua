-- Adds an LSP "waiting for reply" spinner (see `lua/utils/lsp_pending.lua`) as its own statusline
-- entry, just left of the LSP client names. The rest of the list mirrors AstroNvim's default statusline.

---@type LazySpec
return {
  "rebelot/heirline.nvim",
  opts = function(_, opts)
    local status = require "astroui.status"
    local pending = require "utils.lsp_pending"
    pending.setup()

    opts.statusline = {
      hl = { fg = "fg", bg = "bg" },
      status.component.mode(),
      status.component.git_branch(),
      status.component.file_info(),
      status.component.git_diff(),
      status.component.diagnostics(),
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
