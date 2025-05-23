return {
  {
    "olimorris/codecompanion.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter",
      "ravitemer/codecompanion-history.nvim",
    },
    opts = {
      extensions = {
        history = {
          enabled = true,
          opts = {
            keymap = "gh",
            save_chat_keymap = "sc",
            auto_save = true,
            expiration_days = 0,
            picker = "telescope",
            auto_generate_title = true,
            title_generation_opts = { adapter = nil, model = nil },
            continue_last_chat = false,
            delete_on_clearing_chat = false,
            dir_to_save = vim.fn.stdpath "data" .. "/codecompanion-history",
            enable_logging = false,
          },
        },
      },
    },
    keys = {
      {
        "<leader>a",
        desc = "AI",
        mode = "n",
      },
      {
        "<leader>ac",
        "<cmd>CodeCompanionChat<CR>",
        desc = "Chat",
        mode = "n",
      },
      {
        "<leader>ah",
        "<cmd>CodeCompanionHistory<CR>",
        desc = "History",
        mode = "n",
      },
    },
  },
}
