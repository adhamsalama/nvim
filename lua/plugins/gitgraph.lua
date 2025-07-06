local function goto_next_commit()
  local cursor = vim.api.nvim_win_get_cursor(0) -- Get current cursor position
  local next_line = cursor[1] + 2 -- Move 2 lines down

  -- Get the line content
  local line = vim.api.nvim_buf_get_lines(0, next_line - 1, next_line, false)[1]
  if line then
    -- Find the last glyph (* or M) before the hash
    local col = line:find "[%*M]" or 1
    vim.api.nvim_win_set_cursor(0, { next_line, col })
  else
    vim.notify("No next commit found", vim.log.levels.INFO)
  end
end

local function goto_prev_commit()
  local cursor = vim.api.nvim_win_get_cursor(0) -- Get current cursor position
  local prev_line = math.max(1, cursor[1] - 2) -- Move 2 lines up, ensuring we don't go past line 1

  -- Get the line content
  local line = vim.api.nvim_buf_get_lines(0, prev_line - 1, prev_line, false)[1]
  if line then
    -- Find the last glyph (* or M) before the hash
    local col = line:find "[%*M]" or 1
    vim.api.nvim_win_set_cursor(0, { prev_line, col })
  else
    vim.notify("No previous commit found", vim.log.levels.INFO)
  end
end
-- Set up autocommand for buffer-local mappings when in a GitGraph buffer.
vim.api.nvim_create_augroup("GitGraphMappings", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
  group = "GitGraphMappings",
  pattern = "gitgraph", -- adjust if your GitGraph buffer uses a different filetype
  callback = function()
    vim.keymap.set("n", "]c", goto_next_commit, { buffer = true, desc = "Go to next commit" })
    vim.keymap.set("n", "[c", goto_prev_commit, { buffer = true, desc = "Go to previous commit" })
  end,
})
return {
  {
    "adhamsalama/gitgraph.nvim", -- the same repo name AstroNvim expects
    -- dev = true, -- tells AstroNvim to load the local version in dev mode
    -- dir = "~/code/gitgraph.nvim", -- your local path to the plugin
    opts = {
      symbols = {
        merge_commit = "M",
        commit = "*",
      },
      format = {
        timestamp = "%a, %d %b %Y, %I:%M:%S %p",
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
        function() require("gitgraph").draw({}, {}) end,
        desc = "GitGraph - Draw",
      },
    },
  },
}
