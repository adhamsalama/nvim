-- Snacks picker over tab pages (<Leader>ft), like the buffers picker. Each tab shows its name (`vim.t.name`, see
-- lua/plugins/tab-names.lua) or number, the file in its current window and how many buffers its tabline holds; the
-- preview shows a copy of that window's buffer at its cursor. Also the destination picker of <Leader>btm (`opts`).

local M = {}

-- Every buffer is copied into the preview's scratch buffer (file buffers with their syntax highlighting), never shown
-- itself: showing a file buffer in the preview window added it to the current tab's buffers (AstroNvim's per-tab
-- tracking), and showing a plugin buffer (the Claude and kubectl terminals, GitGraph's panels) fired its plugin's
-- BufWinEnter handling, which opened it in a split of the editor window.
---@param ctx snacks.picker.preview.ctx
local function preview(ctx)
  local buf = ctx.item.buf
  if not vim.api.nvim_buf_is_valid(buf) then return ctx.preview:reset() end
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
  if vim.bo[buf].buftype == "" and vim.bo[buf].filetype ~= "" then
    ctx.preview:highlight { ft = vim.bo[buf].filetype }
  end
  local win = ctx.preview.win.win
  if win and vim.api.nvim_win_is_valid(win) and #lines > 0 then
    local row = is_term and #lines or math.min(ctx.item.pos[1], #lines)
    vim.api.nvim_win_set_cursor(win, { row, 0 })
  end
end

---@class TabPickerOpts
---@field title? string
---@field exclude? fun(tab: integer): boolean tabs to leave out
---@field new_tab? boolean add a "New tab" item (its `tab` is nil)
---@field confirm? fun(tab: integer?) what to do with the chosen tab (default: go to it)

---@param opts? TabPickerOpts
function M.pick(opts)
  opts = opts or {}
  local current = vim.api.nvim_get_current_tabpage()
  local items, width = {}, 0
  for nr, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if not (opts.exclude and opts.exclude(tab)) then
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
  end
  if opts.new_tab then
    width = math.max(width, 1)
    items[#items + 1] = { text = "new tab", label = "+", file_label = "New tab", new = true, nbufs = 0 }
  end

  Snacks.picker.pick {
    title = opts.title or "Tabs",
    focus = "list", -- start in the list to move with j/k; `i` or `/` goes to the input
    items = items,
    format = function(item)
      return {
        { item.current and "● " or "  ", "SnacksPickerSpecial" },
        { item.label .. string.rep(" ", width - vim.api.nvim_strwidth(item.label) + 1), "SnacksPickerLabel" },
        { item.file_label, item.new and "SnacksPickerSpecial" or "SnacksPickerFile" },
        { item.nbufs > 1 and ("  +" .. (item.nbufs - 1)) or "", "SnacksPickerBufFlags" },
      }
    end,
    preview = function(ctx)
      if not ctx.item.new then return preview(ctx) end
      ctx.preview:reset()
      ctx.preview:set_title "New tab"
      ctx.preview:set_lines { "Opens a new tab, in front of the plugin tabs." }
    end,
    confirm = function(picker, item)
      picker:close()
      if not item then return end
      if opts.confirm then return opts.confirm(item.tab) end
      if vim.api.nvim_tabpage_is_valid(item.tab) then vim.api.nvim_set_current_tabpage(item.tab) end
    end,
  }
end

return M
