-- if true then return end -- WARN: REMOVE THIS LINE TO ACTIVATE THIS FILE

-- This will run last in the setup process and is a good place to configure
-- things like custom filetypes. This is just pure lua so anything that doesn't
-- fit in the normal config locations above can go here

-- Set up custom filetypes
-- vim.filetype.add {
--   extension = {
--     foo = "fooscript",
--   },
--   filename = {
--     ["Foofile"] = "fooscript",
--   },
--   pattern = {
--     ["~/%.config/foo/.*"] = "fooscript",
--   },
-- }

-- vim.keymap.set("n", "<leader>gd", "<cmd>DiffviewOpen<cr>", { desc = "View Git diff" })

vim.opt.guicursor = "n-v-c-sm:block,ci-ve:ver25,r-cr-o:hor20,i:block-blinkwait700-blinkoff400-blinkon250-Cursor/lCursor"

-- Custom quickfix text function to hide column numbers
_G.qftextfunc_no_col = function(info)
  local items
  local ret = {}
  if info.quickfix == 1 then
    items = vim.fn.getqflist({ id = info.id, items = 0 }).items
  else
    items = vim.fn.getloclist(info.winid, { id = info.id, items = 0 }).items
  end

  for i = info.start_idx, info.end_idx do
    local e = items[i]
    local str
    if e.valid == 1 then
      local fname = ""
      if e.bufnr > 0 then
        fname = vim.fn.bufname(e.bufnr)
        if fname == "" then
          fname = "[No Name]"
        else
          -- Make path relative to current working directory
          local cwd = vim.fn.getcwd()
          if fname:sub(1, #cwd) == cwd then
            fname = fname:sub(#cwd + 2) -- +2 to skip the trailing slash
          else
            -- Fallback to home directory substitution if not in cwd
            fname = fname:gsub("^" .. vim.env.HOME, "~")
          end
        end
      end

      local lnum = e.lnum > 0 and e.lnum or 0
      local text = e.text or ""

      -- Format: filename|line| text (without column)
      if fname ~= "" then
        str = string.format("%s|%d| %s", fname, lnum, text)
      else
        str = string.format("|%d| %s", lnum, text)
      end
    else
      str = e.text
    end
    table.insert(ret, str)
  end
  return ret
end

-- Quickfix history picker
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
        local display = string.format("[%d]%s %s (%d items)  %s", entry.nr, entry.marker, entry.title, entry.size, entry.hint)
        return {
          value = entry,
          display = display,
          ordinal = entry.title .. " " .. entry.hint,
        }
      end,
    }),
    sorter = require("telescope.config").values.generic_sorter({}),
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
        vim.cmd("copen")
      end)
      return true
    end,
  }):find()
end, { desc = "Quickfix history picker" })

-- Add keymap to delete quickfix/location list entries with "dd"
vim.api.nvim_create_autocmd("FileType", {
  pattern = "qf",
  callback = function(event)
    vim.keymap.set("n", "dd", function()
      -- Get current line number
      local line = vim.fn.line "."

      -- Check if this is a location list or quickfix list
      local is_loclist = vim.fn.getloclist(0, { filewinid = 0 }).filewinid ~= 0

      if is_loclist then
        -- Location list
        local items = vim.fn.getloclist(0, { items = 0 }).items
        table.remove(items, line)
        vim.fn.setloclist(0, {}, "r", { items = items })
      else
        -- Quickfix list
        local items = vim.fn.getqflist({ items = 0 }).items
        table.remove(items, line)
        vim.fn.setqflist({}, "r", { items = items })
      end

      -- Restore cursor position
      local new_last_line = vim.fn.line "$"
      local target_line = math.min(line, new_last_line)
      vim.fn.cursor(target_line, 0)
    end, { buffer = event.buf, desc = "Delete quickfix/location list entry" })
  end,
})
