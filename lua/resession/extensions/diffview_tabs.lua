-- Resession extension that brings Diffview tabs back. A session can't restore a view (its windows show diffview://
-- buffers and panels), so each view remembers the arguments that opened it (`track`, run when diffview loads), the
-- session saves them with the view's tab, and the view reopens in that tab the first time you enter it. Not during the
-- load: a view runs git synchronously, and the startup work still pending (LSP setup starting a process per buffer)
-- would run nested inside it. Registered in `lua/plugins/diffview.lua`.

local M = {}

---@class DiffviewRestore
---@field cmd "open"|"file_history"
---@field args string[]

-- Arguments that reopen the view the same anywhere: file names expanded (`%`, `#`), the repository given with -C, and a
-- line range (:'<,'>DiffviewFileHistory, <Leader>gF) as -L, since the range applies to the current buffer.
---@return string[]
local function portable_args(view, args)
  local out = {}
  for _, arg in ipairs(args or {}) do
    table.insert(out, arg:match "^[%%#]" and vim.fn.expand(arg, false) --[[@as string]] or arg)
  end
  local toplevel = view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel
  if toplevel and not vim.iter(out):any(function(a) return a:match "^%-C" ~= nil end) then
    table.insert(out, 1, "-C" .. toplevel)
  end
  return out
end

local MAX_NAME = 32

---Tab name for a view, from the arguments that opened it: `Diff HEAD~2`, `History auth.js`, `History auth.js:26-35`
---(<Leader>gF), `Search <text>` (<Leader>gL), `Stash`, with commit hashes shortened.
---@param restore DiffviewRestore
---@return string
local function tab_name(restore)
  local targets, line, search, range = {}, nil, nil, nil
  for _, arg in ipairs(restore.args) do
    if arg:match "^%-L" then
      line = arg:sub(3)
    elseif arg:match "^%-[GS]" then
      search = arg:sub(3):gsub("\\(.)", "%1")
    elseif arg:match "^%-%-range=" then
      range = arg:match "=(.*)"
    elseif not arg:match "^%-" then
      table.insert(targets, arg)
    end
  end
  local name
  if restore.cmd == "open" then
    name = vim.trim("Diff " .. table.concat(targets, " "))
  elseif search then
    name = "Search " .. search
  elseif range == "stash" then
    name = "Stash"
  elseif line then
    local first, last, file = line:match "^(%d+),(%d+):(.*)$"
    name = file and ("History %s:%s-%s"):format(vim.fs.basename(file), first, last) or "History"
  elseif #targets > 0 then
    name = "History " .. (#targets == 1 and vim.fs.basename(targets[1]) or (#targets .. " paths"))
  else
    name = vim.trim("History " .. (range or ""))
  end
  name = name:gsub("(%x%x%x%x%x%x%x)%x%x%x+", "%1")
  if vim.fn.strchars(name) > MAX_NAME then name = vim.fn.strcharpart(name, 0, MAX_NAME - 1) .. "…" end
  return name
end

---Makes the view's tab a plugin tab (lua/resession/extensions/tab_names.lua `is_plugin_tab`): named after the view,
---and kept with the plugin tabs on the right by the TabNew handler in lua/plugins/tab-names.lua. Called from diffview's
---`view_opened` hook, right after the view's tab opens.
function M.mark(view)
  local tab = view.tabpage
  if not (tab and vim.api.nvim_tabpage_is_valid(tab)) then return end
  vim.t[tab].plugin_tab = true
  vim.t[tab].name = view.session_restore and tab_name(view.session_restore) or "Diffview"
  vim.cmd.redrawtabline()
end

-- Wraps diffview's view constructors so each view records how to reopen it.
function M.track()
  local lib = require "diffview.lib"
  local diffview_open, file_history = lib.diffview_open, lib.file_history
  lib.diffview_open = function(args, ...)
    local view = diffview_open(args, ...)
    if view then view.session_restore = { cmd = "open", args = portable_args(view, args) } end
    return view
  end
  lib.file_history = function(range, args, ...)
    local view = file_history(range, args, ...)
    if view then
      local restore_args = portable_args(view, args)
      local line_trace = range and vim.tbl_get(view, "panel", "log_options", "single_file", "L")
      if line_trace and line_trace[1] then table.insert(restore_args, "-L" .. line_trace[1]) end
      view.session_restore = { cmd = "file_history", args = restore_args }
    end
    return view
  end
end

function M.on_save()
  local index = {}
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    index[tab] = i
  end
  local views = {}
  -- tabs from the last load that were never entered keep their view to reopen
  for tab, i in pairs(index) do
    local pending = vim.t[tab].diffview_restore ---@type DiffviewRestore?
    if pending then table.insert(views, { tab = i, cmd = pending.cmd, args = pending.args }) end
  end
  local lib = package.loaded["diffview.lib"] -- no views when diffview never loaded
  for _, view in ipairs(lib and lib.views or {}) do
    local restore = view.session_restore ---@type DiffviewRestore?
    if restore and index[view.tabpage] then
      table.insert(views, { tab = index[view.tabpage], cmd = restore.cmd, args = restore.args })
    end
  end
  return { views = views }
end

-- Reopens the view of the current tab, if it has one to reopen: the view opens in a new tab right after this one, which
-- then closes, so the view takes its place.
local function reopen_here()
  local tab = vim.api.nvim_get_current_tabpage()
  local restore = vim.t[tab].diffview_restore ---@type DiffviewRestore?
  if not restore then return end
  vim.t[tab].diffview_restore = nil
  local diffview = require "diffview"
  if restore.cmd == "open" then
    diffview.open(restore.args)
  else
    diffview.file_history(nil, restore.args)
  end
  local view_tab = vim.api.nvim_get_current_tabpage()
  if view_tab == tab then return end
  -- after the TabNew handler has moved the new plugin tab to the end: back right after this tab, which then closes
  vim.schedule(function()
    if not vim.api.nvim_tabpage_is_valid(tab) then return end
    if vim.api.nvim_tabpage_is_valid(view_tab) and vim.api.nvim_get_current_tabpage() == view_tab then
      vim.cmd("tabmove " .. vim.api.nvim_tabpage_get_number(tab))
    end
    pcall(vim.cmd.tabclose, vim.api.nvim_tabpage_get_number(tab))
  end)
end

local augroup = vim.api.nvim_create_augroup("DiffviewTabsRestore", { clear = true })
vim.api.nvim_create_autocmd("TabEnter", {
  group = augroup,
  desc = "Reopen a Diffview view from the session in this tab",
  callback = function()
    local tab = vim.api.nvim_get_current_tabpage()
    if not vim.t[tab].diffview_restore then return end
    -- only where you stay: other extensions pass through tabs while a session loads
    vim.defer_fn(function()
      if vim.api.nvim_get_current_tabpage() == tab then reopen_here() end
    end, 100)
  end,
})

function M.on_post_load(data)
  local tabpages = vim.api.nvim_list_tabpages()
  local current = vim.api.nvim_get_current_tabpage()
  for _, view in ipairs(data.views or {}) do
    local tab = tabpages[view.tab]
    if tab then
      local restore = { cmd = view.cmd, args = view.args }
      vim.t[tab].diffview_restore = restore
      vim.t[tab].plugin_tab = true
      vim.t[tab].name = tab_name(restore)
    end
  end
  -- the tab current after the load (no TabEnter for it): once the load and the startup work after it are done
  if vim.t[current].diffview_restore then
    vim.defer_fn(function()
      if vim.api.nvim_get_current_tabpage() == current then reopen_here() end
    end, 1000)
  end
end

return M
