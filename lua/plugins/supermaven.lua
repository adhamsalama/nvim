return {
  "supermaven-inc/supermaven-nvim",
  event = "VimEnter",

  config = function()
    require("supermaven-nvim").setup {
      keymaps = {
        accept_suggestion = "<Tab>",
        accept_word = "<C-j>",
        clear_suggestion = "<C-]>",
      },

      -- Disable per-buffer via ignore_filetypes (checked at completion time,
      -- does NOT stop the binary). Do NOT use `condition` for this: on BufEnter
      -- a truthy condition calls api.stop(), which latches vim.g.SUPERMAVEN_DISABLED = 1
      -- globally and is never reset, killing suggestions in every other buffer too.
      ignore_filetypes = { "env" },

      disable_inline_completion = false,
      log_level = "info",
    }
  end,
  -- {
  --   "rebelot/heirline.nvim",
  --   opts = function(_, opts)
  --     local status = require "astroui.status"
  --
  --     local supermaven_component = status.component.builder {
  --       condition = function() return vim.bo.buftype == "" end,
  --       {
  --         provider = function()
  --           local ok, _ = pcall(require, "supermaven-nvim.api")
  --           if not ok then return "" end
  --           return "supermaven"
  --         end,
  --       },
  --       padding = { left = 1, right = 1 },
  --       update = { "BufEnter", "FocusGained" },
  --     }
  --
  --     -- insert after lsp (index 9)
  --     table.insert(opts.statusline, 10, supermaven_component)
  --   end,
  -- },
}
