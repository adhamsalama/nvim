-- if true then return {} end -- WARN: REMOVE THIS LINE TO ACTIVATE THIS FILE
return {
  "rmagatti/goto-preview",
  event = "BufEnter",
  config = function()
    require("goto-preview").setup {
      -- width = 120, -- Width of the floating window
      -- height = 15, -- Height of the floating window
      -- border = { "↖", "─", "┐", "│", "┘", "─", "└", "│" }, -- Border characters of the floating window
      -- default_mappings = false, -- Bind default mappings
      -- debug = false, -- Print debug information
      -- opacity = nil, -- 0-100 opacity level of the floating window where 100 is fully transparent.
      resizing_mappings = true, -- Binds arrow keys to resizing the floating window.
      -- post_open_hook = nil, -- A function taking two arguments, a buffer and a window to be ran as a hook.
      -- post_close_hook = nil, -- A function taking two arguments, a buffer and a window to be ran as a hook.
      -- references = { -- Configure the telescope UI for slowing the references cycling window.
      --   provider = "telescope", -- telescope|fzf_lua|snacks|mini_pick|default
      --   telescope = require("telescope.themes").get_dropdown { hide_preview = false },
      -- },
      -- These two configs can also be passed down to the goto-preview definition and implementation calls for one off "peak" functionality.
      -- focus_on_open = true, -- Focus the floating window when opening it.
      -- dismiss_on_move = false, -- Dismiss the floating window when moving the cursor.
      -- force_close = true, -- passed into vim.api.nvim_win_close's second argument. See :h nvim_win_close
      -- bufhidden = "wipe", -- the bufhidden option to set on the floating window. See :h bufhidden
      -- stack_floating_preview_windows = true, -- Whether to nest floating windows
      -- same_file_float_preview = true, -- Whether to open a new floating window for a reference within the current file
      -- preview_window_title = { enable = true, position = "left" }, -- Whether to set the preview window title as the filename
      -- zindex = 1, -- Starting zindex for the stack of floating windows
      -- vim_ui_input = true, -- Whether to override vim.ui.input with a goto-preview floating window
    } -- Ensure plugin is properly configured

    -- Define key mappings under <leader>lg
    local keymaps = {
      ["<leader>lgD"] = { function() require("goto-preview").goto_preview_declaration() end, "Preview Declaration" },
      ["<leader>lgP"] = { function() require("goto-preview").close_all_win() end, "Close Preview Windows" },
      ["<leader>lgd"] = { function() require("goto-preview").goto_preview_definition() end, "Preview Definition" },
      ["<leader>lgi"] = {
        function() require("goto-preview").goto_preview_implementation() end,
        "Preview Implementation",
      },
      ["<leader>lgr"] = { function() require("goto-preview").goto_preview_references() end, "Preview References" },
      ["<leader>lgt"] = {
        function() require("goto-preview").goto_preview_type_definition() end,
        "Preview Type Definition",
      },
    }
    vim.keymap.set("n", "<leader>lg", "<Nop>", { desc = "LSP & Goto Preview" })
    -- Register keymaps
    for key, map in pairs(keymaps) do
      vim.keymap.set("n", key, map[1], { desc = map[2], silent = true })
    end
  end,
}
