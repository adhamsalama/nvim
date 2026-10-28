-- Pin buffers to the left of the AstroNvim heirline tabline. Pins belong to the
-- session they were made in: they live on the buffer (`vim.b.pinned`) and are
-- saved/restored by the resession extension in
-- `lua/resession/extensions/pin_buffer.lua`, so a fresh Neovim without a session
-- starts with nothing pinned and each session only restores its own pins.
--
-- AstroNvim renders the tabline straight from `vim.t.bufs` (a per-tab ordered
-- list of buffer numbers), so "pinning to the left" just means keeping the
-- pinned buffers at the front of that list every time it changes.
-- `lua/plugins/pin-buffer.lua` wires this to the keymap, the `AstroBufsUpdated`
-- event, resession, and the tabline icon.

local M = {}

---@param bufnr? integer defaults to the current buffer
---@return boolean
function M.is_pinned(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].pinned == true
end

-- Reorder a tab's `vim.t.bufs` so pinned buffers come first, preserving the
-- relative order within each group. Only writes back (and repaints) when the
-- order actually changes, which keeps this safe to call from the event that
-- firing it would otherwise re-trigger.
---@param tabpage? integer defaults to the current tab
function M.reorder(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local bufs = vim.t[tabpage].bufs
  if not bufs then return end
  local front, back = {}, {}
  for _, bufnr in ipairs(bufs) do
    table.insert(M.is_pinned(bufnr) and front or back, bufnr)
  end
  local merged = vim.list_extend(front, back)
  if not vim.deep_equal(merged, bufs) then
    vim.t[tabpage].bufs = merged
    require("astrocore").event "BufsUpdated"
    vim.cmd.redrawtabline()
  end
end

-- Toggle the pin on a buffer, then slide it into place.
---@param bufnr? integer defaults to the current buffer
function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(bufnr) == "" then
    vim.notify("pin_buffer: can't pin a buffer with no file", vim.log.levels.WARN)
    return
  end
  vim.b[bufnr].pinned = not M.is_pinned(bufnr) or nil
  M.reorder()
  -- reorder() only repaints when the buffer order changes, but toggling the pin
  -- on an already-leftmost (or sole) buffer flips the icon without moving it, so
  -- force a tabline redraw here to refresh the indicator immediately.
  vim.cmd.redrawtabline()
end

return M
