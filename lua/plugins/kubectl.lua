return {
  {
    "ramilito/kubectl.nvim",
    version = "2.0.1",
    dependencies = "saghen/blink.download",
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
