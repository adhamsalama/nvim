-- Pin buffers to the left of the AstroNvim heirline tabline.
--
-- AstroNvim renders the tabline straight from `vim.t.bufs` (a per-tab ordered
-- list of buffer numbers), so "pinning to the left" just means keeping the
-- pinned buffers at the front of that list every time it changes. We track the
-- pinned set here and re-partition `vim.t.bufs` on demand; `lua/plugins/pin-buffer.lua`
-- wires this to the `AstroBufsUpdated` event, a keymap, and a tabline icon.

local M = {}

-- Set of pinned buffers, keyed by bufnr. Global (not per-tab) so a buffer stays
-- pinned wherever it appears; good enough for a single-tab workflow.
---@type table<integer, true>
local pinned = {}

---@param bufnr? integer defaults to the current buffer
---@return boolean
function M.is_pinned(bufnr) return pinned[bufnr or vim.api.nvim_get_current_buf()] == true end

-- Reorder `vim.t.bufs` so pinned buffers come first, preserving the relative
-- order within each group. Only writes back (and repaints) when the order
-- actually changes, which keeps this safe to call from the event that firing it
-- would otherwise re-trigger.
function M.reorder()
  local bufs = vim.t.bufs
  if not bufs then return end
  local front, back = {}, {}
  for _, bufnr in ipairs(bufs) do
    table.insert(pinned[bufnr] and front or back, bufnr)
  end
  local merged = vim.list_extend(front, back)
  if not vim.deep_equal(merged, bufs) then
    vim.t.bufs = merged
    require("astrocore").event "BufsUpdated"
    vim.cmd.redrawtabline()
  end
end

-- Toggle the pin on a buffer, then slide it into place.
---@param bufnr? integer defaults to the current buffer
function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pinned[bufnr] = not pinned[bufnr] or nil
  M.reorder()
  -- reorder() only repaints when the buffer order changes, but toggling the pin
  -- on an already-leftmost (or sole) buffer flips the icon without moving it, so
  -- force a tabline redraw here to refresh the indicator immediately.
  vim.cmd.redrawtabline()
end

-- Drop a buffer from the pinned set (call when it is deleted/wiped).
---@param bufnr integer
function M.forget(bufnr) pinned[bufnr] = nil end

return M
