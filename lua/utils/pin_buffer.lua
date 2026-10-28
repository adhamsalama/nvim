-- Pin buffers to the left of the AstroNvim heirline tabline, persisted per
-- working directory so pins survive restarts and session loads.
--
-- AstroNvim renders the tabline straight from `vim.t.bufs` (a per-tab ordered
-- list of buffer numbers), so "pinning to the left" just means keeping the
-- pinned buffers at the front of that list every time it changes. We track the
-- pinned set here keyed by absolute file path (stable across sessions, unlike
-- buffer numbers) and persist it to a per-cwd JSON file under stdpath("data").
-- `lua/plugins/pin-buffer.lua` wires this to the keymap, the `AstroBufsUpdated`
-- event, session/dir changes, and the tabline icon.

local M = {}

-- Set of pinned files for the current working directory, keyed by normalized
-- absolute path. Repopulated from disk by `load()` whenever the cwd changes.
---@type table<string, true>
local pinned = {}

local data_dir = vim.fs.joinpath(vim.fn.stdpath "data", "pin_buffer")

-- The on-disk store for the current cwd. Pins are scoped per project directory,
-- mirroring the old vim-bookmarks `save_per_working_dir` behavior.
local function store_file()
  local slug = vim.fs.normalize(vim.fn.getcwd()):gsub("[^%w]", "_")
  return vim.fs.joinpath(data_dir, slug .. ".json")
end

-- Normalized absolute path of a buffer, or nil for unnamed/special buffers.
---@param bufnr integer
---@return string?
local function path_of(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return nil end
  return vim.fs.normalize(name)
end

local function save()
  vim.fn.mkdir(data_dir, "p")
  local paths = vim.tbl_keys(pinned)
  table.sort(paths) -- stable file contents for easier diffing
  local ok, encoded = pcall(vim.json.encode, paths)
  if not ok then return end
  local f = io.open(store_file(), "w")
  if f then
    f:write(encoded)
    f:close()
  end
end

-- Replace the in-memory pinned set with the one saved for the current cwd.
function M.load()
  pinned = {}
  local f = io.open(store_file(), "r")
  if not f then return end
  local content = f:read "*a"
  f:close()
  local ok, paths = pcall(vim.json.decode, content)
  if ok and type(paths) == "table" then
    for _, p in ipairs(paths) do
      pinned[vim.fs.normalize(p)] = true
    end
  end
end

---@param bufnr? integer defaults to the current buffer
---@return boolean
function M.is_pinned(bufnr)
  local p = path_of(bufnr or vim.api.nvim_get_current_buf())
  return p ~= nil and pinned[p] == true
end

-- Reorder `vim.t.bufs` so pinned buffers come first, preserving the relative
-- order within each group. Only writes back (and repaints) when the order
-- actually changes, which keeps this safe to call from the event that firing it
-- would otherwise re-trigger.
function M.reorder()
  local bufs = vim.t.bufs
  if not bufs then return end
  local front, back = {}, {}
  for _, bufnr in ipairs(bufs) do
    table.insert(M.is_pinned(bufnr) and front or back, bufnr)
  end
  local merged = vim.list_extend(front, back)
  if not vim.deep_equal(merged, bufs) then
    vim.t.bufs = merged
    require("astrocore").event "BufsUpdated"
    vim.cmd.redrawtabline()
  end
end

-- Load the current cwd's pins and slide them into place. Called on startup,
-- after a session loads, and when the working directory changes.
function M.refresh()
  M.load()
  M.reorder()
  vim.cmd.redrawtabline()
end

-- Toggle the pin on a buffer, persist, then slide it into place.
---@param bufnr? integer defaults to the current buffer
function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local p = path_of(bufnr)
  if not p then
    vim.notify("pin_buffer: can't pin a buffer with no file", vim.log.levels.WARN)
    return
  end
  pinned[p] = not pinned[p] or nil
  save()
  M.reorder()
  -- reorder() only repaints when the buffer order changes, but toggling the pin
  -- on an already-leftmost (or sole) buffer flips the icon without moving it, so
  -- force a tabline redraw here to refresh the indicator immediately.
  vim.cmd.redrawtabline()
end

return M
