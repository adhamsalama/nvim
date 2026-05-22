return {
  dir = vim.fn.stdpath "config",
  name = "quickfix-history",
  lazy = false,
  dependencies = { "nvim-telescope/telescope.nvim" },
  config = function()
    vim.keymap.set("n", "<leader>fq", function()
      local lists = {}
      local total = vim.fn.getqflist({ nr = "$" }).nr
      local current = vim.fn.getqflist({ nr = 0 }).nr
      for i = 1, total do
        local list = vim.fn.getqflist({ nr = i, title = 0, size = 0, items = 0 })
        local first = list.items and list.items[1]
        local hint = first and vim.fn.bufname(first.bufnr) or ""
        hint = hint ~= "" and hint:gsub("^" .. vim.fn.getcwd() .. "/", "") or hint
        local marker = i == current and " *" or ""
        table.insert(lists, { nr = i, title = list.title, size = list.size, hint = hint, marker = marker })
      end

      local conf = require("telescope.config").values
      local previewer = require("telescope.previewers").new_buffer_previewer({
        title = "Preview",
        define_preview = function(self, entry)
          local list = vim.fn.getqflist({ nr = entry.value.nr, items = 0 })
          local first = list.items and list.items[1]
          if not first or first.bufnr == 0 then return end
          local filename = vim.fn.bufname(first.bufnr)
          if filename == "" then return end
          conf.buffer_previewer_maker(filename, self.state.bufnr, {
            bufname = self.state.bufname,
            winid = self.state.winid,
            callback = function()
              pcall(vim.api.nvim_win_set_cursor, self.state.winid, { first.lnum, first.col })
            end,
          })
        end,
      })

      require("telescope.pickers").new({}, {
        prompt_title = "Quickfix History",
        previewer = previewer,
        finder = require("telescope.finders").new_table({
          results = lists,
          entry_maker = function(entry)
            local display =
              string.format("[%d]%s %s (%d items)  %s", entry.nr, entry.marker, entry.title, entry.size, entry.hint)
            return {
              value = entry,
              display = display,
              ordinal = entry.title .. " " .. entry.hint,
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, _)
          require("telescope.actions").select_default:replace(function()
            local selection = require("telescope.actions.state").get_selected_entry()
            require("telescope.actions").close(prompt_bufnr)
            local delta = selection.value.nr - vim.fn.getqflist({ nr = 0 }).nr
            if delta > 0 then
              vim.cmd("silent cnewer " .. delta)
            elseif delta < 0 then
              vim.cmd("silent colder " .. math.abs(delta))
            end
            vim.cmd "copen"
          end)
          return true
        end,
      }):find()
    end, { desc = "Quickfix history picker" })
  end,
}
