return {
  {
    "MattesGroeger/vim-bookmarks",
    dependencies = {
      {
        "AstroNvim/astrocore",
        opts = {
          mappings = {
            n = {
              ["<Leader>m"] = { name = "Bookmarks" },
              ["<Leader>ma"] = { "<Cmd>BookmarkAnnotate<CR>", desc = "Annotate Bookmark" },
              ["<Leader>mc"] = { "<Cmd>BookmarkClear<CR>", desc = "Clear Bookmarks" },
              ["<Leader>ml"] = { "<Cmd>BookmarkShowAll<CR>", desc = "List Bookmarks" },
              ["<Leader>mm"] = { "<Cmd>BookmarkToggle<CR>", desc = "Toggle Bookmark" },
              ["<Leader>mn"] = { "<Cmd>BookmarkNext<CR>", desc = "Next Bookmark" },
              ["<Leader>mp"] = { "<Cmd>BookmarkPrev<CR>", desc = "Previous Bookmark" },
            },
          },
        },
      },
    },
    config = function()
      vim.g.bookmark_sign = "⚑"
      vim.g.bookmark_annotation_sign = "☰"
      vim.g.bookmark_save_per_working_dir = 1
    end,
  },

  -- The dashboard's Bookmarks key (') opens AstroNvim's marks picker (<Leader>f'); pick from these bookmarks instead,
  -- in a Snacks picker (<Leader>ml keeps the quickfix list).
  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      local function pick_bookmarks()
        -- Saving per working dir, vim-bookmarks loads the working dir's bookmarks file only once a file is opened
        -- (BufEnter), so on the dashboard none are loaded yet. Opening a file later loads the same file again.
        if vim.fn["bm#total_count"]() == 0 then
          local file = vim.fn.exists "*g:BMWorkDirFileLocation" == 1 and vim.fn["g:BMWorkDirFileLocation"]()
            or vim.fn.getcwd() .. "/.vim-bookmarks"
          if vim.fn.filereadable(file) == 1 then vim.fn.BookmarkLoad(file, 1, 1) end
        end
        local items = {}
        -- "file:line:text", sorted by file and line; text is the annotation when there is one
        for _, loc in ipairs(vim.fn["bm#location_list"]()) do
          local file, lnum, text = loc:match "^(.-):(%d+):(.*)$"
          if file then
            table.insert(items, { file = file, pos = { tonumber(lnum), 0 }, line = text, text = file .. " " .. text })
          end
        end
        require("snacks").picker.pick { title = "Bookmarks", items = items, format = "file", preview = "file" }
      end
      local keys = vim.tbl_get(opts, "dashboard", "preset", "keys") or {}
      for _, key in ipairs(keys) do
        if key.key == "'" then key.action = pick_bookmarks end
      end
    end,
  },
}
