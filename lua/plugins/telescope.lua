return {
  "nvim-telescope/telescope.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  keys = {
    { "<leader>gb", "<cmd>Telescope git_branches<cr>", desc = "Show Git Branches" },
  },
}
