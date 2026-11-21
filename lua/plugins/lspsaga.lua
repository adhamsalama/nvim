-- Lspsaga, used *only* for its call hierarchy tree.
--
-- Deliberately not using the `astrocommunity.lsp.lspsaga-nvim` pack: that one also remaps
-- `K`, `gd`, rename, code action and the diagnostic jumps over AstroNvim's defaults.
-- Here the plugin stays unloaded until `:Lspsaga` or one of the two keymaps below is used.
--
-- `saga.setup()` only has three load-time side effects (lspsaga/init.lua:203-222):
--   * lightbulb autocmd            -> disabled below
--   * symbol:register_module()     -> runs unconditionally, but every branch inside is gated
--                                     on `symbol_in_winbar.enable` / `implement.enable`
--   * diagnostic_only_current      -> already false by default
-- Everything else in lspsaga is command-triggered, so leaving it unmapped keeps it inert.

---@type LazySpec
return {
  -- The python pack's venv-selector maps <Leader>lv (Select VirtualEnv) through astrocore, which runs after the
  -- lazy key below is set and replaces it. Drop that mapping; :VenvSelect still works.
  { "AstroNvim/astrocore", opts = { mappings = { n = { ["<Leader>lv"] = false } } } },
  {
    "nvimdev/lspsaga.nvim",
    cmd = "Lspsaga",
    keys = {
      { "<Leader>lc", "<Cmd>Lspsaga incoming_calls<CR>", desc = "Incoming calls" },
      { "<Leader>lC", "<Cmd>Lspsaga outgoing_calls<CR>", desc = "Outgoing calls" },
      {
        "<Leader>lv",
        function() require("lspsaga.callhierarchy"):restore_last() end,
        desc = "Reopen last call hierarchy",
      },
    },
    opts = {
      -- we have our own winbar (see `lua/plugins/astroui.lua`)
      symbol_in_winbar = { enable = false },
      lightbulb = { enable = false },
      implement = { enable = false },
      beacon = { enable = false },
      callhierarchy = {
        layout = "float",
        left_width = 0.35, -- wider tree pane (default 0.2) so deeply nested names aren't truncated
        keys = {
          edit = "<CR>",
          vsplit = "s",
          split = "i",
          tabe = "t",
          quit = "q",
          close = "<C-c>k",
          shuttle = "[w",
          toggle_or_req = "<Tab>", -- expand a node to request the next level
        },
      },
    },
    config = function(_, opts)
      require("lspsaga").setup(opts)

      -- lspsaga jumps with vim.lsp.util.jump_to_location (callhierarchy.lua:256, typehierarchy.lua:256), deprecated
      -- since Nvim 0.11: it warns on every jump and will be removed. Same behavior as Nvim's own wrapper, no warning.
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.lsp.util.jump_to_location = function(location, encoding, reuse_win)
        return vim.lsp.util.show_document(location, encoding, { reuse_win = reuse_win, focus = true })
      end

      -- lspsaga hardcodes the call-hierarchy float at half the screen height (callhierarchy.lua:380),
      -- which is cramped for deep trees. `layout:left` is the single chokepoint for both the initial
      -- render and `restore_last`, so raise the height there (width stays config-driven via left_width).
      local layout = require "lspsaga.layout"
      local orig_layout_left = layout.left
      layout.left = function(self, height, width, ...)
        return orig_layout_left(self, math.max(height, math.floor(vim.o.lines * 0.85) - 4), width, ...)
      end

      -- Call-site previews, reference-driven levels for what tsgo can't follow, variables as roots:
      -- see lua/lsp/callhierarchy/init.lua
      require("lsp.callhierarchy").setup()
      -- Tree history (`<`/`>` in the tree, <Leader>lv reopens), `?` key list, `dd`/visual `d` to prune entries,
      -- duplicate-entry marks, heirline winbar on the preview
      require("lsp.callhierarchy.ui").setup()
    end,
  },
}
