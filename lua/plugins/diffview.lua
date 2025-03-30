return {
  "sindrets/diffview.nvim",
  keys = {
    { "<leader>gd", "<Nop>", desc = "Diffview" },
    { "<leader>gdd", "<cmd>DiffviewOpen<cr>", desc = "Diff view" },
    { "<leader>gdf", "<cmd>DiffviewFileHistory %<cr>", desc = "File History" },
    { "<leader>gdh", "<cmd>DiffviewFileHistory<cr>", desc = "Repo History" },
    { "<leader>gds", "<cmd>DiffviewFileHistory -g --range=stash<cr>", desc = "View Stash" },
    -- { "<leader>gdm", "<cmd>DiffviewOpen origin/HEAD...HEAD --imply-local<cr>", desc = "Review" },
    {
      "<leader>gdr",
      function()
        vim.ui.input({ prompt = "Enter branch to compare (leave empty for origin/HEAD): " }, function(branch)
          local target = (branch and branch ~= "") and ("origin/" .. branch) or "origin/HEAD"
          vim.cmd("DiffviewOpen " .. target .. "...HEAD --imply-local")
        end)
      end,
      desc = "Review",
    },
    {
      "<leader>gdc",
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
      desc = "Diff commit of line",
    },
  },
  opts = function(_, opts)
    local actions = require "diffview.actions"

    opts.keymaps = {
      view = {
        ["<leader>b"] = false, -- Focus files panel in Diffview
        { "n", "<leader>e", actions.toggle_files, { desc = "Toggle the file panel." } },
        -- ["<leader>e"] = actions.toggle_files, -- Focus files panel in Diffview
      },
      file_panel = {
        ["<leader>b"] = false, -- Focus files panel in Diffview
        { "n", "<leader>e", actions.toggle_files, { desc = "Toggle the file panel." } },
        -- ["<leader>e"] = actions.toggle_files,
      },
      file_history_panel = {
        ["<leader>b"] = false, -- Focus files panel in Diffview
        { "n", "<leader>e", actions.toggle_files, { desc = "Toggle the file panel." } },
        -- ["<leader>e"] = actions.toggle_files,
      },
      diff1 = {
        ["<leader>b"] = false, -- Focus files panel in Diffview
        { "n", "<leader>e", actions.toggle_files, { desc = "Toggle the file panel." } },
        -- ["<leader>e"] = actions.toggle_files, -- Focus files panel in Diffview
      },
      diff2 = {
        ["<leader>b"] = false, -- Focus files panel in Diffview
        { "n", "<leader>e", actions.toggle_files, { desc = "Toggle the file panel." } },
        -- ["<leader>e"] = actions.toggle_files, -- Focus files panel in Diffview
      },
      diff3 = {
        ["<leader>b"] = false, -- Focus files panel in Diffview
        { "n", "<leader>e", actions.toggle_files, { desc = "Toggle the file panel." } },
        -- ["<leader>e"] = actions.toggle_files, -- Focus files panel in Diffview
      },
    }
  end,
}
