-- Debounce LSP pull diagnostics. Nvim 0.12 sends `textDocument/diagnostic` after every didChange
-- and cancels the previous one, but tsgo keeps computing cancelled pulls (on a 19k-line file each
-- takes seconds), so hover/completion queue behind dozens of dead requests.
--
-- Wraps the private `vim.lsp.diagnostic._refresh` (re-check on Nvim upgrades):
--   * all buffers: coalesce pulls within `delay_ms`
--   * long buffers (`vim.b.lsp_lite`, see large-buf-lsp.lua): longer delay, never while in insert
--     mode, and hidden buffers are only pulled when shown again

local M = {}

M.delay_ms = 400
M.lite_delay_ms = 1500

---@type table<integer, {timer: uv.uv_timer_t, client_id: integer?, only_visible: boolean, set: boolean}>
local state = {}

local function visible(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then return true end
  end
  return false
end

function M.setup()
  local diag = vim.lsp.diagnostic
  if diag._debounced or type(diag._refresh) ~= "function" then return end
  local orig = diag._refresh
  diag._debounced = true

  local function fire(bufnr)
    local s = state[bufnr]
    if not s then return end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      s.timer:close()
      state[bufnr] = nil
      return
    end
    local lite = vim.b[bufnr].lsp_lite
    if lite and vim.fn.mode():find "^[iR]" then
      return s.timer:start(M.lite_delay_ms, 0, vim.schedule_wrap(function() fire(bufnr) end))
    end
    if lite and not visible(bufnr) then
      vim.b[bufnr].lsp_diag_stale = true
      s.set = false
      return
    end
    local client_id, only_visible = s.client_id, s.only_visible
    s.set = false
    orig(bufnr, client_id, only_visible)
  end

  ---@diagnostic disable-next-line: duplicate-set-field
  diag._refresh = function(bufnr, client_id, only_visible)
    bufnr = vim._resolve_bufnr(bufnr)
    local s = state[bufnr]
    if not s then
      local timer = vim.uv.new_timer()
      if not timer then return orig(bufnr, client_id, only_visible) end
      s = { timer = timer, set = false, only_visible = false }
      state[bufnr] = s
    end
    -- merge pending calls: different clients -> all clients; any full refresh wins over visible-only
    if s.set then
      if s.client_id ~= client_id then s.client_id = nil end
      s.only_visible = s.only_visible and only_visible or false
    else
      s.client_id, s.only_visible, s.set = client_id, only_visible or false, true
    end
    s.timer:stop()
    local delay = vim.b[bufnr].lsp_lite and M.lite_delay_ms or M.delay_ms
    s.timer:start(delay, 0, vim.schedule_wrap(function() fire(bufnr) end))
  end

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = vim.api.nvim_create_augroup("lsp_diag_debounce", { clear = true }),
    desc = "Pull diagnostics skipped while a long buffer was hidden",
    callback = function(args)
      if not vim.b[args.buf].lsp_diag_stale then return end
      vim.b[args.buf].lsp_diag_stale = nil
      diag._refresh(args.buf)
    end,
  })
end

return M
