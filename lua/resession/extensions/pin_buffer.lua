-- Resession extension that saves and restores buffer pins (`vim.b.pinned`, set
-- by `lua/utils/pin_buffer.lua`). Registered in `lua/plugins/pin-buffer.lua`.

local M = {}

---@param opts resession.Extension.OnSaveOpts
function M.on_save(opts)
  local pin = require "utils.pin_buffer"
  -- a tab-scoped session only holds its own tab's buffers
  local bufs = opts.tabpage and (vim.t[opts.tabpage].bufs or {}) or vim.api.nvim_list_bufs()
  local paths = {}
  for _, bufnr in ipairs(bufs) do
    if pin.is_pinned(bufnr) then table.insert(paths, vim.api.nvim_buf_get_name(bufnr)) end
  end
  return { paths = paths }
end

function M.on_post_load(data)
  local pin = require "utils.pin_buffer"
  for _, path in ipairs(data.paths or {}) do
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 then vim.b[bufnr].pinned = true end
  end
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    pin.reorder(tabpage)
  end
  vim.cmd.redrawtabline()
end

return M
