-- documentHighlight for long buffers, replacing snacks.words there (it's disabled per buffer with
-- vim.b.snacks_words = false). snacks.words sends a request every time the cursor rests 200ms; on a
-- 19k-line file tsgo takes seconds per reply and ignores $/cancelRequest, so they pile up in front
-- of hover. Here, for buffers `is_lite` says yes to:
--   * normal mode only, after the cursor rests `delay_ms`
--   * no request while the cursor stays inside the current highlights or isn't on a keyword char
--   * at most one request per buffer in flight; moves meanwhile queue one fresh request after it
--   * a reply is drawn only if the cursor and buffer are unchanged since it was sent
-- Highlights go in the legacy "vim_lsp_references" namespace: Snacks.words.get/jump read it (so ]r / [r
-- work), but snacks' per-move vim.lsp.buf.clear_references() on disabled buffers doesn't clear it.
-- Follows the snacks words toggle (<Leader>uR) via Snacks.words.enabled / vim.g.snacks_words.

local M = {}

M.delay_ms = 500

local method = "textDocument/documentHighlight"
local ns = vim.api.nvim_create_namespace "vim_lsp_references"
local kind_hl = { "LspReferenceText", "LspReferenceRead", "LspReferenceWrite" }

---@param bufnr integer
local function clear(bufnr) vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1) end

---@param bufnr integer
---@param refs lsp.DocumentHighlight[]
---@param encoding string
local function draw(bufnr, refs, encoding)
  local nlines = vim.api.nvim_buf_line_count(bufnr)
  local function col(row, character)
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local ok, c = pcall(vim.str_byteindex, line, encoding, character, false)
    return ok and c or #line
  end
  for _, ref in ipairs(refs) do
    local s, e = ref.range.start, ref.range["end"]
    if s.line < nlines then
      local erow = math.min(e.line, nlines - 1)
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, s.line, col(s.line, s.character), {
        end_row = erow,
        end_col = col(erow, e.character),
        hl_group = kind_hl[ref.kind or 1] or kind_hl[1],
        priority = vim.hl.priorities.user,
      })
    end
  end
end

---@type fun(bufnr: integer): boolean
local is_lite = function(_) return false end

---@class lsp_words_lite.State
---@field timer uv.uv_timer_t
---@field inflight boolean
---@field dirty boolean

---@type table<integer, lsp_words_lite.State>
local states = {}

local function globally_enabled()
  local ok, snacks = pcall(require, "snacks")
  return vim.g.snacks_words ~= false and (not ok or snacks.words.enabled)
end

---@param bufnr integer
local function state(bufnr)
  local s = states[bufnr]
  if not s then
    s = { timer = assert(vim.uv.new_timer()), inflight = false, dirty = false }
    states[bufnr] = s
  end
  return s
end

---@param bufnr integer
local function cursor_in_highlight(bufnr)
  local ok, snacks = pcall(require, "snacks")
  if not ok then return false end
  return vim.api.nvim_buf_call(bufnr, function() return select(2, snacks.words.get()) ~= nil end)
end

local function on_keyword()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local ch = vim.api.nvim_get_current_line():sub(col + 1, col + 1)
  return ch ~= "" and vim.fn.match(ch, [[\k]]) == 0
end

local request

---@param bufnr integer
local function schedule(bufnr)
  local s = state(bufnr)
  s.timer:stop()
  s.timer:start(
    M.delay_ms,
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr then request(bufnr) end
    end)
  )
end

---@param bufnr integer
function request(bufnr)
  local s = state(bufnr)
  if s.inflight then
    s.dirty = true
    return
  end
  if not globally_enabled() or vim.api.nvim_get_mode().mode ~= "n" or not on_keyword() then return end
  local clients = vim.lsp.get_clients { bufnr = bufnr, method = method }
  if #clients == 0 then return end

  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local tick = vim.b[bufnr].changedtick
  local pending = #clients
  local results = {} ---@type {client: vim.lsp.Client, result: lsp.DocumentHighlight[]}[]
  s.inflight, s.dirty = true, false

  local function done()
    pending = pending - 1
    if pending > 0 then return end
    s.inflight = false
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local fresh = vim.api.nvim_get_current_buf() == bufnr
      and vim.api.nvim_get_current_win() == win
      and vim.b[bufnr].changedtick == tick
      and vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor)
    if fresh then
      clear(bufnr)
      for _, r in ipairs(results) do
        draw(bufnr, r.result, r.client.offset_encoding)
      end
    elseif s.dirty then
      schedule(bufnr)
    end
  end

  for _, client in ipairs(clients) do
    local params = vim.lsp.util.make_position_params(win, client.offset_encoding)
    local ok = client:request(method, params, function(err, result)
      if not err and result then results[#results + 1] = { client = client, result = result } end
      done()
    end, bufnr)
    if not ok then done() end
  end
end

---@param opts {is_lite: fun(bufnr: integer): boolean}
function M.setup(opts)
  is_lite = opts.is_lite
  local group = vim.api.nvim_create_augroup("lsp_words_lite", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "ModeChanged" }, {
    group = group,
    callback = function(args)
      local bufnr = args.buf
      if vim.bo[bufnr].buftype ~= "" or not is_lite(bufnr) then return end
      if not globally_enabled() or vim.api.nvim_get_mode().mode ~= "n" then
        if states[bufnr] then states[bufnr].timer:stop() end
        clear(bufnr)
        return
      end
      if cursor_in_highlight(bufnr) then return end
      clear(bufnr)
      schedule(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
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
