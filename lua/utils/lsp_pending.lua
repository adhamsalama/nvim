-- Statusline spinner while an LSP request for the current buffer is waiting on a reply.
-- Driven by the `LspRequest` autocmd (fires on pending/complete/cancel); a timer animates the
-- spinner only while something is pending.

local M = {}

-- Requests Neovim/plugins fire on their own in the background; they'd keep the spinner on constantly.
M.ignored = {
  ["textDocument/semanticTokens/full"] = true,
  ["textDocument/semanticTokens/full/delta"] = true,
  ["textDocument/semanticTokens/range"] = true,
  ["textDocument/inlayHint"] = true,
  ["textDocument/documentHighlight"] = true,
  ["textDocument/codeLens"] = true,
  ["textDocument/foldingRange"] = true,
  ["textDocument/diagnostic"] = true,
  ["textDocument/documentSymbol"] = true,
  ["textDocument/documentColor"] = true,
  ["textDocument/documentLink"] = true,
  ["workspace/diagnostic"] = true,
}

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local timer ---@type uv.uv_timer_t?

--- Method of a visible pending request (for `bufnr`, or any buffer when nil).
---@param bufnr? integer
---@return string?
function M.pending(bufnr)
  for _, client in ipairs(vim.lsp.get_clients(bufnr and { bufnr = bufnr } or nil)) do
    for _, req in pairs(client.requests) do
      if req.type == "pending" and not M.ignored[req.method] and (not bufnr or req.bufnr == bufnr) then
        return req.method
      end
    end
  end
end

--- Statusline text: spinner + short method name, e.g. "⠹ hover".
---@param bufnr integer
---@return string
function M.status(bufnr)
  local method = M.pending(bufnr)
  if not method then return "" end
  local frame = frames[math.floor(vim.uv.hrtime() / 8e7) % #frames + 1]
  return frame .. " " .. method:gsub("^.*/", "")
end

local function stop()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function on_request()
  if M.pending() then
    if timer then return end
    timer = vim.uv.new_timer()
    if not timer then return end
    timer:start(
      0,
      80,
      vim.schedule_wrap(function()
        if not M.pending() then stop() end
        vim.cmd.redrawstatus()
      end)
    )
  end
end

function M.setup()
  vim.api.nvim_create_autocmd("LspRequest", {
    group = vim.api.nvim_create_augroup("lsp_pending_spinner", { clear = true }),
    desc = "Animate the LSP pending-request spinner",
    callback = vim.schedule_wrap(on_request),
  })
end

return M
