return {
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
}
