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
      -- Each preview's title starts with its depth in the stack (1 = opened from a normal window, 2 = from
      -- preview 1, ...). Shift+arrows move the preview window around (plain arrows resize it). The maps live on
      -- the previewed file's buffer, so outside a float they fall back to the key's built-in behavior.
      post_open_hook = function(buf, win)
        -- The depth comes from the window the preview is anchored to, not goto-preview's own window list: its
        -- WinClosed handler drops the *current* window from that list whenever any window closes (e.g. the
        -- which-key popup for `gL`). The hook also runs each time a preview is re-entered, so number it once.
        local cfg = vim.api.nvim_win_get_config(win)
        if cfg.relative == "win" and not vim.w[win].goto_preview_depth then
          local parent = cfg.win
          local depth = (parent and vim.api.nvim_win_is_valid(parent) and vim.w[parent].goto_preview_depth or 0) + 1
          vim.w[win].goto_preview_depth = depth
          local title = cfg.title or {}
          if type(title) == "string" then title = { { title } } end
          table.insert(title, 1, { " " .. depth .. " ", "IncSearch" })
          table.insert(title, 2, { " " })
          vim.api.nvim_win_set_config(win, { title = title, title_pos = cfg.title_pos or "left" })
        end

        local function move(key, dr, dc)
          return function()
            local win = vim.api.nvim_get_current_win()
            if vim.api.nvim_win_get_config(win).relative == "" then return key end
            vim.schedule(function()
              if not vim.api.nvim_win_is_valid(win) then return end
              local cfg = vim.api.nvim_win_get_config(win)
              cfg.row, cfg.col = cfg.row + dr, cfg.col + dc
              vim.api.nvim_win_set_config(win, cfg)
            end)
            return ""
          end
        end
        local o = { buffer = buf, nowait = true, expr = true }
        vim.keymap.set("n", "<S-Left>", move("<S-Left>", 0, -4), o)
        vim.keymap.set("n", "<S-Right>", move("<S-Right>", 0, 4), o)
        vim.keymap.set("n", "<S-Up>", move("<S-Up>", -2, 0), o)
        vim.keymap.set("n", "<S-Down>", move("<S-Down>", 2, 0), o)
      end,
      -- post_close_hook = nil, -- A function taking two arguments, a buffer and a window to be ran as a hook.
      references = { provider = "snacks" }, -- telescope|fzf_lua|snacks|mini_pick|default
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
      ["gLD"] = { function() require("goto-preview").goto_preview_declaration() end, "Preview Declaration" },
      ["gLP"] = { function() require("goto-preview").close_all_win() end, "Close Preview Windows" },
      ["gLd"] = { function() require("goto-preview").goto_preview_definition() end, "Preview Definition" },
      ["gLi"] = {
        function() require("goto-preview").goto_preview_implementation() end,
        "Preview Implementation",
      },
      ["gLr"] = { function() require("goto-preview").goto_preview_references() end, "Preview References" },
      ["gLt"] = {
        function() require("goto-preview").goto_preview_type_definition() end,
        "Preview Type Definition",
      },
    }
    vim.keymap.set("n", "gL", "<Nop>", { desc = "LSP & Goto Preview" })
    -- Register keymaps
    for key, map in pairs(keymaps) do
      vim.keymap.set("n", key, map[1], { desc = map[2], silent = true })
    end
  end,
}
