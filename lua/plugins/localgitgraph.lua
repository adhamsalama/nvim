return {
  {
    "isakbm/gitgraph.nvim", -- the same repo name AstroNvim expects
    dev = true, -- tells AstroNvim to load the local version in dev mode
    dir = "~/code/gitgraph.nvim", -- your local path to the plugin
    opts = {
      symbols = {
        merge_commit = "M",
        commit = "*",
      },
      format = {
        timestamp = "%H:%M:%S %d-%m-%Y",
        fields = { "hash", "author", "timestamp", "branch_name", "tag" },
      },

      hooks = {
        -- Check file history of a commit
        on_select_commit = function(commit)
          vim.notify("DiffviewFileHistory --range=" .. commit.hash .. "^!")
          vim.cmd("DiffviewFileHistory --range=" .. commit.hash .. "^!")
        end,
        -- Check file history from commit a -> commit b
        on_select_range_commit = function(from, to)
          vim.notify("DiffviewFileHistory --range=" .. from.hash .. "~1.." .. to.hash)
          vim.cmd("DiffviewFileHistory --range=" .. from.hash .. "~1.." .. to.hash)
        end,
      },
    },
    keys = {
      {
        "<leader>gv",
        function() require("gitgraph").draw({}, { max_count = 500 }) end,
        desc = "GitGraph - Draw",
      },
    },
  },
}
