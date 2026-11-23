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
  { import = "astrocommunity.pack.golangci-lint" },
  { import = "astrocommunity.pack.java" },
  -- Import sub-packs explicitly: importing "astrocommunity.pack.python" makes lazy.nvim load every
  -- sub-pack in that directory (pyrefly, ty, black, isort, ...), not just its init.lua.
  { import = "astrocommunity.pack.python.base" }, -- debugpy, venv-selector, neotest
  { import = "astrocommunity.pack.python.basedpyright" },
  { import = "astrocommunity.pack.python.ruff" }, -- lint + format (replaces black/isort)
  { import = "astrocommunity.pack.rust" },
  { import = "astrocommunity.pack.yaml" },
  { import = "astrocommunity.markdown-and-latex.render-markdown-nvim" },
  -- Programming related stuff
  { import = "astrocommunity.pack.full-dadbod" },
  { import = "astrocommunity.docker.lazydocker" },
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

  { import = "astrocommunity.quickfix.nvim-bqf" },
  { import = "astrocommunity.search.grug-far-nvim" },
  { import = "astrocommunity.scrolling.neoscroll-nvim" },
  { import = "astrocommunity.editing-support.nvim-treesitter-context" },
  { import = "astrocommunity.recipes.heirline-vscode-winbar" },
  { import = "astrocommunity.recipes.heirline-mode-text-statusline" },
}
