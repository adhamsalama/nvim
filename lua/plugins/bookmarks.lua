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
}
