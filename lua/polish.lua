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

-- Keep markdown code-fence backticks/language concealed in LSP hover & signature floats,
-- even after stepping into the popup (K twice). Neovim stylizes these floats with the
-- treesitter markdown parser (conceallevel=2) but hardcodes `concealcursor = ''`
-- (runtime lua/vim/lsp/util.lua), so the fence on the cursor's line is revealed once the
-- cursor enters the window. Re-enable concealcursor on the float so the fences stay hidden.
do
  local orig = vim.lsp.util.open_floating_preview
  vim.lsp.util.open_floating_preview = function(...)
    local bufnr, winnr = orig(...)
    if winnr and vim.api.nvim_win_is_valid(winnr) then vim.wo[winnr].concealcursor = "nvic" end
    return bufnr, winnr
  end
end

-- Truncate long inlay hints for tsc to prevent multi-line wrapping
do
  local max_len = 40
  local orig = vim.lsp.handlers["textDocument/inlayHint"]
  vim.lsp.handlers["textDocument/inlayHint"] = function(err, result, ctx, config)
    local client = vim.lsp.get_client_by_id(ctx.client_id)
    if client and client.name == "tsc" and result then
      for _, hint in ipairs(result) do
        if type(hint.label) == "string" then
          if #hint.label > max_len then hint.label = hint.label:sub(1, max_len) .. "…" end
        elseif type(hint.label) == "table" then
          local total = 0
          for i, part in ipairs(hint.label) do
            local val = part.value or ""
            if total >= max_len then
              hint.label[i].value = ""
            elseif total + #val > max_len then
              hint.label[i].value = val:sub(1, max_len - total) .. "…"
              for j = i + 1, #hint.label do
                hint.label[j].value = ""
              end
              break
            else
              total = total + #val
            end
          end
        end
      end
    end
    return orig(err, result, ctx, config)
  end
end

-- Delete quickfix/location list entries first..last (1-based, inclusive)
local function qf_delete_range(first, last)
  -- Check if this is a location list or quickfix list
  local is_loclist = vim.fn.getloclist(0, { filewinid = 0 }).filewinid ~= 0

  local items = is_loclist and vim.fn.getloclist(0, { items = 0 }).items or vim.fn.getqflist({ items = 0 }).items
  for i = last, first, -1 do
    table.remove(items, i)
  end

  if is_loclist then
    vim.fn.setloclist(0, {}, "r", { items = items })
  else
    vim.fn.setqflist({}, "r", { items = items })
  end

  -- Restore cursor position
  local new_last_line = vim.fn.line "$"
  local target_line = math.min(first, new_last_line)
  vim.fn.cursor(target_line, 0)
end

-- Add keymaps to delete quickfix/location list entries with "dd" and visual "d"
vim.api.nvim_create_autocmd("FileType", {
  pattern = "qf",
  callback = function(event)
    vim.keymap.set("n", "dd", function()
      local line = vim.fn.line "."
      qf_delete_range(line, line)
    end, { buffer = event.buf, desc = "Delete quickfix/location list entry" })

    vim.keymap.set("x", "d", function()
      local first, last = vim.fn.line "v", vim.fn.line "."
      if first > last then
        first, last = last, first
      end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      qf_delete_range(first, last)
    end, { buffer = event.buf, desc = "Delete selected quickfix/location list entries" })
  end,
})

-- Closing a buffer only removes it from the current tab while another tab still has it
require("utils.tab_buffer").setup()
