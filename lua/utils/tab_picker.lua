-- Snacks picker over tab pages (<Leader>ft), like the buffers picker. Each tab shows its name (`vim.t.name`, see
-- lua/plugins/tab-names.lua) or number, the file in its current window and how many buffers its tabline holds; the
-- preview shows that window's buffer at its cursor.

local M = {}

-- File buffers preview as themselves. Plugin buffers (the Claude and kubectl terminals, GitGraph's panels) are copied
-- into the preview's scratch buffer instead: showing them in the preview window fires their plugins' BufWinEnter
-- handling, which opened them in a split of the editor window.
---@param ctx snacks.picker.preview.ctx
local function preview(ctx)
  local buf = ctx.item.buf
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype == "" then return Snacks.picker.preview.file(ctx) end
  ctx.preview:reset()
  ctx.preview:set_title(ctx.item.label)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local is_term = vim.bo[buf].buftype == "terminal"
  if is_term then -- drop the terminal's empty rows below the output
    while #lines > 0 and lines[#lines]:match "^%s*$" do
      table.remove(lines)
    end
  end
  ctx.preview:set_lines(lines)
  local win = ctx.preview.win.win
  if win and vim.api.nvim_win_is_valid(win) and #lines > 0 then
    local row = is_term and #lines or math.min(ctx.item.pos[1], #lines)
    vim.api.nvim_win_set_cursor(win, { row, 0 })
  end
end

function M.pick()
  local current = vim.api.nvim_get_current_tabpage()
  local items, width = {}, 0
  for nr, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local win = vim.api.nvim_tabpage_get_win(tab)
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    local label = vim.t[tab].name or tostring(nr)
    local file = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]"
    width = math.max(width, vim.api.nvim_strwidth(label))
    items[#items + 1] = {
      text = label .. " " .. file,
      tab = tab,
      label = label,
      file_label = file,
      buf = buf,
      pos = vim.api.nvim_win_get_cursor(win),
      current = tab == current,
      nbufs = #(vim.t[tab].bufs or {}),
    }
  end

  Snacks.picker.pick {
    title = "Tabs",
    items = items,
    format = function(item)
      return {
        { item.current and "● " or "  ", "SnacksPickerSpecial" },
        { item.label .. string.rep(" ", width - vim.api.nvim_strwidth(item.label) + 1), "SnacksPickerLabel" },
        { item.file_label, "SnacksPickerFile" },
        { item.nbufs > 1 and ("  +" .. (item.nbufs - 1)) or "", "SnacksPickerBufFlags" },
      }
    end,
    preview = preview,
    confirm = function(picker, item)
      picker:close()
      if item and vim.api.nvim_tabpage_is_valid(item.tab) then vim.api.nvim_set_current_tabpage(item.tab) end
    end,
  }
end

return M
