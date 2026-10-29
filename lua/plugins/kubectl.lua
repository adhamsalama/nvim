return {
  {
    "ramilito/kubectl.nvim",
    version = "2.43.1",
    dependencies = "saghen/blink.download",
    config = function() require("kubectl").setup() end,
    keys = {
      {
        "<leader>tk",
        function()
          local kubectl = require "kubectl"
          local opening = not kubectl.is_open
          kubectl.toggle { tab = true }
          -- toggle opens the new tab synchronously, so it's current here
          if opening then
            vim.t.name = "kubectl"
            vim.cmd.redrawtabline()
          end
        end,
        desc = "Toggle kubectl UI",
        mode = "n",
      },
    },
  },
}
