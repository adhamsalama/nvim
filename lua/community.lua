-- if true then return {} end -- WARN: REMOVE THIS LINE TO ACTIVATE THIS FILE

-- AstroCommunity: import any community modules here
-- We import this file in `lazy_setup.lua` before the `plugins/` folder.
-- This guarantees that the specs are processed before any user plugins.

---@type LazySpec
return {
  "AstroNvim/astrocommunity",
  -- Programming languages
  { import = "astrocommunity.pack.lua" },
  { import = "astrocommunity.pack.typescript" },
  { import = "astrocommunity.pack.go" },
  -- { import = "astrocommunity.pack.java" },
  { import = "astrocommunity.pack.python" },
  { import = "astrocommunity.pack.rust" },
  -- Programming related stuff
  { import = "astrocommunity.pack.full-dadbod" },
  -- { import = "astrocommunity.git.blame-nvim" },
  -- { import = "astrocommunity.git.git-blame-nvim" },
  -- { import = "astrocommunity.git.fugit2-nvim" },
  { import = "astrocommunity.git.diffview-nvim" },
  -- { import = "astrocommunity.recipes.astrolsp-no-insert-inlay-hints" },
  -- Colorschemes
  { import = "astrocommunity.colorscheme.catppuccin" },
  -- { import = "astrocommunity.colorscheme.github-nvim-theme" },
  -- { import = "astrocommunity.colorscheme.onedarkpro-nvim" },
  { import = "astrocommunity.colorscheme.everforest" },
  { import = "astrocommunity.colorscheme.gruvbox-nvim" },
  { import = "astrocommunity.recipes.telescope-nvim-snacks" },
  { import = "astrocommunity.programming-language-support.rest-nvim" },
}
