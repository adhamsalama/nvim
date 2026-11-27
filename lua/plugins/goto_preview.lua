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
        -- which-key popup for `gp`). The hook also runs each time a preview is re-entered, so number it once.
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
              -- Re-place it relative to the editor at its current screen spot: a stacked preview is anchored to the
              -- preview it came from, and once that one closes its config still names the dead window id.
              local pos = vim.api.nvim_win_get_position(win)
              vim.api.nvim_win_set_config(win, { relative = "editor", row = pos[1] + dr, col = pos[2] + dc })
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
      -- Start above treesitter-context's floats (zindex 20): a preview's sticky context header would otherwise draw
      -- over the previews stacked on top of it. Context headers inside previews end up hidden under their preview.
      zindex = 21,
      -- vim_ui_input = true, -- Whether to override vim.ui.input with a goto-preview floating window
    } -- Ensure plugin is properly configured

    -- A stacked preview is anchored to the preview it was opened from. When that one closes, Neovim re-anchors the
    -- orphan elsewhere (it jumps to another split), so pin it to the editor at its current screen spot first.
    vim.api.nvim_create_autocmd("WinClosed", {
      group = vim.api.nvim_create_augroup("goto_preview_pin_orphans", { clear = true }),
      callback = function(args)
        local closed = tonumber(args.match)
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          local cfg = vim.api.nvim_win_get_config(win)
          if win ~= closed and cfg.relative == "win" and cfg.win == closed and vim.w[win].goto_preview_depth then
            local pos = vim.api.nvim_win_get_position(win)
            vim.api.nvim_win_set_config(win, { relative = "editor", row = pos[1], col = pos[2] })
          end
        end
      end,
    })

    -- goto-preview's snacks provider ignores the locations it got and opens `lsp_references` instead, so with 2+
    -- implementations / type definitions / declarations it listed the symbol's references. Ask through vim.lsp.buf
    -- (same merged results as gi/gy/gD) and pick among them ourselves; the chosen one opens in a preview float.
    -- FIXME: report upstream (rmagatti/goto-preview) and drop this once fixed. In lua/goto-preview/lib.lua the
    -- `snacks` and `fzf_lua` providers are `function(_, _)`: they drop (prompt_title, items) and run their own
    -- lsp_references source. They date from "add support for more picker providers" (4f4134d), when the pickers
    -- only served references; "Add picker for multiple implementations" (7659d15) then routed implementation /
    -- typeDefinition / declaration results (handle_multiple_locations -> open_references_previewer) through the
    -- same providers. telescope and default use `items`; snacks and fzf_lua should too. Repro: gopls, an
    -- interface method with 2 implementations, references.provider = "snacks", goto_preview_implementation().
    local function preview_locations(method, title)
      return function()
        vim.lsp.buf[method] {
          on_list = function(list)
            local open = function(item)
              require("goto-preview.lib").open_floating_win(
                vim.uri_from_fname(item.filename),
                { item.lnum, item.col - 1 }
              )
            end
            if #list.items == 1 then return open(list.items[1]) end
            Snacks.picker.pick {
              title = title,
              items = vim.tbl_map(
                function(item)
                  return {
                    file = item.filename,
                    pos = { item.lnum, item.col - 1 },
                    line = item.text,
                    text = item.filename .. " " .. item.text,
                    raw = item,
                  }
                end,
                list.items
              ),
              format = "file",
              confirm = function(picker, item)
                picker:close()
                if item then open(item.raw) end
              end,
            }
          end,
        }
      end
    end

    -- `gp` + the LSP key for the same lookup (gd/gD/gI/grr/gy); `gh` is a shortcut for the most common one
    local keymaps = {
      ["gh"] = { function() require("goto-preview").goto_preview_definition() end, "Preview Definition" },
      ["gpd"] = { function() require("goto-preview").goto_preview_definition() end, "Preview Definition" },
      ["gpD"] = { preview_locations("declaration", "Declarations"), "Preview Declaration" },
      ["gpi"] = { preview_locations("implementation", "Implementations"), "Preview Implementation" },
      ["gpr"] = { function() require("goto-preview").goto_preview_references() end, "Preview References" },
      ["gpy"] = { preview_locations("type_definition", "Type Definitions"), "Preview Type Definition" },
      ["gP"] = { function() require("goto-preview").close_all_win() end, "Close Preview Windows" },
    }
    vim.keymap.set("n", "gp", "<Nop>", { desc = "Goto Preview" })
    -- Register keymaps
    for key, map in pairs(keymaps) do
      vim.keymap.set("n", key, map[1], { desc = map[2], silent = true })
    end
  end,
}
