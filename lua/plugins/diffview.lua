return {
  "sindrets/diffview.nvim",
  keys = {
    { "<leader>gd", "<cmd>DiffviewOpen<cr>", desc = "Open Git Diff View" },
    { "<leader>gC", "<cmd>DiffviewClose<cr>", desc = "Close Diff View" },
    { "<leader>gh", "<cmd>DiffviewFileHistory<cr>", desc = "Open Repo History" },
    { "<leader>gH", "<cmd>DiffviewFileHistory %<cr>", desc = "Open File History" },
    {
      "<leader>gL",
      function()
        -- Run `git blame` on the current line and extract the commit hash
        local line_num = vim.fn.line "." -- Get the current line number
        local file_path = vim.fn.expand "%" -- Get the current file path
        local blame_output = vim.fn.system("git blame -L " .. line_num .. "," .. line_num .. " " .. file_path)

        -- Extract the commit hash (first word of blame output)
        local commit_hash = blame_output:match "^(%x+)"

        -- Handle cases where no valid commit hash is found
        if not commit_hash or string.find("00000000000000", commit_hash) then
          vim.notify("Not committed", vim.log.levels.INFO)
          return
        end

        vim.cmd("DiffviewFileHistory --range=" .. commit_hash .. "^!") -- This one works
        -- local commit_hash = vim.fn.expand "<cword>"
        -- vim.cmd("DiffviewOpen " .. commit_hash .. "^!")
        -- vim.cmd("DiffviewFileHistory -r " .. commit_hash .. "^!" .. " " .. file_path)
        -- vim.cmd("DiffviewFileHistory --range=" .. commit_hash .. " -1 " .. file_path)
      end,
      desc = "Full Blame",
    },
  },
}
