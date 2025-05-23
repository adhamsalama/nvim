return {
  {
    "ramilito/kubectl.nvim",
    config = function() require("kubectl").setup() end,
    keys = {
      {
        "<leader>tk",
        function() require("kubectl").toggle { tab = true } end,
        desc = "Toggle kubectl UI",
        mode = "n",
      },
    },
  },
}
