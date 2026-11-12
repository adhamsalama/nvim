-- Inlay hints for the visible part of long buffers only (VS Code style). Nvim 0.12 asks for hints
-- over the WHOLE buffer after every change and never cancels the old request; tsgo type-checks all
-- 19k lines each time and hover queues behind dozens of those.
--
-- For buffers `is_lite` says yes to:
--   * Nvim's own whole-buffer `textDocument/inlayHint` requests are swallowed (Client.request is
--     wrapped) and turned into a trigger for this module
--   * we request the visible lines of every window showing the buffer plus one screen above/below,
--     after scroll/resize/edit, with a delay that adapts to how slowly the server answered recently
--   * at most one request per buffer and client is in flight (tsgo ignores $/cancelRequest); changes
--     meanwhile mark it dirty and one fresh request follows the reply
--   * hints are inline extmarks, so old ones move with edits and stay until the new reply lands
-- On/off still follows vim.lsp.inlay_hint.is_enabled(), so <Leader>uh / <Leader>uH keep working.
-- Wraps Nvim internals (Client.request, util._make_line_range_params): re-check on Nvim upgrades.

local M = {}

M.max_label = 40 -- same cap as the tsc handler in polish.lua
M.min_delay_ms = 75
M.max_delay_ms = 750

local method = "textDocument/inlayHint"
local ns = vim.api.nvim_create_namespace "lsp_inlay_range"

---@type fun(bufnr: integer): boolean
local is_lite = function() return false end

---@class lsp_inlay_range.State
---@field timer uv.uv_timer_t
---@field inflight table<integer, boolean> client id -> request outstanding
---@field dirty boolean
---@field avg_ms number

---@type table<integer, lsp_inlay_range.State>
local states = {}

local function enabled(bufnr) return vim.lsp.inlay_hint.is_enabled { bufnr = bufnr } end

---@param bufnr integer
---@return integer? first, integer? last 0-based line range covering every window on the buffer
local function wanted_range(bufnr)
  local first, last
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local info = vim.fn.getwininfo(win)[1]
    if info then
      local margin = info.height
      local s = math.max(info.topline - 1 - margin, 0)
      local e = info.botline - 1 + margin
      first = first and math.min(first, s) or s
      last = last and math.max(last, e) or e
    end
  end
  if not first then return end
  return first, math.min(last, vim.api.nvim_buf_line_count(bufnr) - 1)
end

local function label_text(label)
  local text = label
  if type(label) == "table" then
    local parts = {}
    for _, part in ipairs(label) do
      parts[#parts + 1] = part.value or ""
    end
    text = table.concat(parts)
  end
  if vim.fn.strchars(text) > M.max_label then text = vim.fn.strcharpart(text, 0, M.max_label) .. "…" end
  return text
end

---@param client vim.lsp.Client
local function render(bufnr, client, first, last, hints)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, first, last + 1)
  local by_pos = {} ---@type table<string, {row: integer, col: integer, vt: [string, string?][]}>
  local lines = vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false)
  for _, hint in ipairs(hints or {}) do
    local row = hint.position.line
    local line = lines[row - first + 1]
    if line then
      local col = vim.str_byteindex(line, client.offset_encoding, hint.position.character, false)
      local key = row .. ":" .. col
      local entry = by_pos[key] or { row = row, col = col, vt = {} }
      by_pos[key] = entry
      if hint.paddingLeft then table.insert(entry.vt, { " " }) end
      table.insert(entry.vt, { label_text(hint.label), "LspInlayHint" })
      if hint.paddingRight then table.insert(entry.vt, { " " }) end
    end
  end
  for _, e in pairs(by_pos) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, e.row, e.col, { virt_text = e.vt, virt_text_pos = "inline" })
  end
end

local schedule

---@param client vim.lsp.Client
local function send(bufnr, client, first, last)
  local s = states[bufnr]
  local version = vim.lsp.util.buf_versions[bufnr]
  local start = vim.uv.hrtime()
  s.inflight[client.id] = true
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    range = vim.lsp.util._make_line_range_params(bufnr, first, last, client.offset_encoding),
  }
  local ok = client:request(method, params, function(err, result)
    s.inflight[client.id] = nil
    s.avg_ms = s.avg_ms * 0.7 + (vim.uv.hrtime() - start) / 1e6 * 0.3
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not err and enabled(bufnr) and vim.lsp.util.buf_versions[bufnr] == version then
      render(bufnr, client, first, last, result)
    elseif not err then
      s.dirty = true -- buffer changed while waiting: positions are stale, ask again
    end
    if s.dirty then schedule(bufnr) end
  end, bufnr)
  if not ok then s.inflight[client.id] = nil end
end

local function fire(bufnr)
  local s = states[bufnr]
  if not s or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if not enabled(bufnr) then return vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1) end
  local first, last = wanted_range(bufnr)
  if not first then return end -- hidden; BufWinEnter retriggers
  s.dirty = false
  for _, client in ipairs(vim.lsp.get_clients { bufnr = bufnr, method = method }) do
    if s.inflight[client.id] then
      s.dirty = true -- one at a time; re-sent when the reply comes in
    else
      send(bufnr, client, first, last)
    end
  end
end

--- Debounced request for `bufnr` (no-op unless it's a long buffer with hints on).
---@param bufnr integer
function schedule(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not is_lite(bufnr) then return end
  local s = states[bufnr]
  if not s then
    local timer = vim.uv.new_timer()
    if not timer then return end
    s = { timer = timer, inflight = {}, dirty = false, avg_ms = 200 }
    states[bufnr] = s
  end
  local delay = math.min(math.max(s.avg_ms / 2, M.min_delay_ms), M.max_delay_ms)
  s.timer:stop()
  s.timer:start(math.floor(delay), 0, vim.schedule_wrap(function() fire(bufnr) end))
end
M.schedule = schedule

---@param opts {is_lite: fun(bufnr: integer): boolean}
function M.setup(opts)
  if M._setup then return end
  M._setup = true
  is_lite = opts.is_lite

  -- swallow Nvim's whole-buffer requests (it passes no handler) on long buffers
  local Client = require "vim.lsp.client"
  local orig_request = Client.request
  ---@diagnostic disable-next-line: duplicate-set-field
  function Client:request(m, params, handler, bufnr)
    if m == method and handler == nil and bufnr and bufnr ~= 0 and is_lite(bufnr) then
      vim.schedule(function() schedule(bufnr) end)
      return true, nil
    end
    return orig_request(self, m, params, handler, bufnr)
  end

  -- follow <Leader>uh / <Leader>uH (and anything else toggling the built-in state)
  local orig_enable = vim.lsp.inlay_hint.enable
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.lsp.inlay_hint.enable = function(enable, filter)
    orig_enable(enable, filter)
    local bufnr = filter and filter.bufnr
    local bufs = bufnr and { vim._resolve_bufnr(bufnr) } or vim.tbl_keys(states)
    for _, b in ipairs(bufs) do
      if vim.api.nvim_buf_is_valid(b) and is_lite(b) then
        if enabled(b) then
          schedule(b)
        else
          vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
        end
      end
    end
  end

  local group = vim.api.nvim_create_augroup("lsp_inlay_range", { clear = true })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    desc = "Request inlay hints for the newly visible lines of long buffers",
    callback = function()
      local seen = {}
      for id in pairs(vim.v.event) do
        local win = tonumber(id)
        if win and vim.api.nvim_win_is_valid(win) then
          local b = vim.api.nvim_win_get_buf(win)
          if not seen[b] then
            seen[b] = true
            schedule(b)
          end
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    desc = "Request inlay hints when a long buffer is shown",
    callback = function(args) schedule(args.buf) end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    group = group,
    callback = function(args)
      local s = states[args.buf]
      if s then
        s.timer:stop()
        s.timer:close()
        states[args.buf] = nil
      end
    end,
  })
end

return M
