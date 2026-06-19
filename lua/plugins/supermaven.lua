return {
  {
    "supermaven-inc/supermaven-nvim",
    lazy = false,

    config = function()
      require("supermaven-nvim").setup {
        keymaps = {
          accept_suggestion = "<Tab>",
          accept_word = "<C-j>",
          clear_suggestion = "<C-]>",
        },

        condition = function()
          local name = vim.fn.expand "%:t"

          -- disable for env files
          if name:match "^%.env" then return true end

          return false
        end,

        disable_inline_completion = false,
        log_level = "off",
      }
    end,
  },
  {
    "rebelot/heirline.nvim",
    opts = function(_, opts)
      local status = require "astroui.status"

      local supermaven_component = status.component.builder {
        condition = function() return vim.bo.buftype == "" end,
        {
          provider = function()
            local ok, _ = pcall(require, "supermaven-nvim.api")
            if not ok then return "" end
            return "supermaven"
          end,
        },
        padding = { left = 1, right = 1 },
        update = { "BufEnter", "FocusGained" },
      }

      -- insert after lsp (index 9)
      table.insert(opts.statusline, 10, supermaven_component)
    end,
  },
}
