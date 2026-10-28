-- Make closing a buffer tab-local.
--
-- AstroNvim's `astrocore.buffer.close` deletes the buffer, and its `BufDelete`
-- autocmd then drops it from every tab's `vim.t.bufs`, so closing a file in one
-- tab also closes it in every other tab that has it open. We wrap `close` so
-- that a buffer still listed in another tab is only removed from the current
-- tab; it is deleted for real only when this is the last tab holding it. Every
-- close path (<Leader>c, the <Leader>bd picker, the tabline close button,
-- close_all/left/right) goes through `close`, so they all pick this up.

local M = {}

---@param bufnr integer
---@return boolean
local function listed_in_other_tab(bufnr)
  local current = vim.api.nvim_get_current_tabpage()
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    if tabpage ~= current and vim.tbl_contains(vim.t[tabpage].bufs or {}, bufnr) then return true end
  end
  return false
end

-- Remove a buffer from the current tab only: windows in this tab that show it
-- switch to a neighboring tab buffer (or a new empty one), and it leaves `vim.t.bufs`.
---@param bufnr integer
local function detach(bufnr)
  local bufs = vim.t.bufs or {}
  local idx = 1
  for i, b in ipairs(bufs) do
    if b == bufnr then idx = i end
  end
  local others = vim.tbl_filter(function(b) return b ~= bufnr end, bufs)
  local replacement = others[math.max(idx - 1, 1)]

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(winid) == bufnr then
      if replacement then
        vim.api.nvim_win_set_buf(winid, replacement)
      else
        vim.api.nvim_win_call(winid, vim.cmd.enew)
      end
    end
  end

  -- re-read: `enew` may have just added the new empty buffer to this tab
  vim.t.bufs = vim.tbl_filter(function(b) return b ~= bufnr end, vim.t.bufs or {})
  require("astrocore").event "BufsUpdated"
  vim.cmd.redrawtabline()
end

function M.setup()
  local buffer = require "astrocore.buffer"
  local close = buffer.close
  buffer.close = function(bufnr, force)
    if not bufnr or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
    if listed_in_other_tab(bufnr) then
      detach(bufnr)
    else
      close(bufnr, force)
    end
  end
end

return M
