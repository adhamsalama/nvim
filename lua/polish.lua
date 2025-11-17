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
          fname = fname:gsub("^" .. vim.env.HOME, "~")
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

      -- Adjust cursor position if we deleted the last line
      if line > vim.fn.line "$" then vim.cmd "normal! k" end
    end, { buffer = event.buf, desc = "Delete quickfix/location list entry" })
  end,
})
