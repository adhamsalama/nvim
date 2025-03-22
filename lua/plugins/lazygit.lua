return {
  {
    "kdheepak/lazygit.nvim",
    config = function()
      -- Set scaling factor to 1 for full screen usage
      vim.g.lazygit_floating_window_scaling_factor = 1
      vim.g.lazygit_floating_window_use_plenary = 0 -- Disable plenary for floating window

      -- Map leader gg to LazyGit command
      vim.api.nvim_set_keymap("n", "<leader>gg", ":LazyGit<CR>", { noremap = true, silent = true })
    end,
  },
}
