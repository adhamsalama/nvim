-- Resession extension that saves and restores tab names (`vim.t.name`, set by
-- `lua/plugins/tab-names.lua`). Registered in that file's resession spec.

local M = {}

---@param opts resession.Extension.OnSaveOpts
function M.on_save(opts)
  -- a tab-scoped session only holds its own tab
  if opts.tabpage then return { tab_scoped = true, names = { vim.t[opts.tabpage].name or vim.NIL } } end
  local names = {}
  for i, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    names[i] = vim.t[tabpage].name or vim.NIL -- keep positions aligned for unnamed tabs
  end
  return { names = names }
end

function M.on_post_load(data)
  local tabpages = vim.api.nvim_list_tabpages()
  if data.tab_scoped then tabpages = { vim.api.nvim_get_current_tabpage() } end
  for i, name in ipairs(data.names) do
    if tabpages[i] and type(name) == "string" then vim.t[tabpages[i]].name = name end
  end
  vim.cmd.redrawtabline()
end

return M
