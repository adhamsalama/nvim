return {
  {
    "kristijanhusak/vim-dadbod-ui",
    keys = {
      {
        "<leader>tD",
        function()
          vim.cmd "tabnew"
          vim.cmd "DBUI"
        end,
        desc = "Open DBUI",
      },
    },
  },
}
