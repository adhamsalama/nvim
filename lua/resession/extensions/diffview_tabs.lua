-- Resession extension that brings Diffview tabs back. A session can't restore a view (its windows show diffview://
-- buffers and panels), so each view remembers the arguments that opened it (`track`, run when diffview loads), the
-- session saves them with the view's tab, and loading reopens each view in that tab's place. Registered in
-- `lua/plugins/diffview.lua`.

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
  local lib = package.loaded["diffview.lib"] -- no views when diffview never loaded
  if not lib then return {} end
  local index = {}
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    index[tab] = i
  end
  local views = {}
  for _, view in ipairs(lib.views) do
    local restore = view.session_restore ---@type DiffviewRestore?
    if restore and index[view.tabpage] then
      table.insert(views, { tab = index[view.tabpage], cmd = restore.cmd, args = restore.args })
    end
  end
  return { views = views }
end

function M.on_post_load(data)
  local tabpages = vim.api.nvim_list_tabpages()
  local targets = {}
  for _, view in ipairs(data.views or {}) do
    if tabpages[view.tab] then table.insert(targets, { tab = tabpages[view.tab], view = view }) end
  end
  if #targets == 0 then return end
  local current
  -- One view at a time: a view keeps loading after it opens (git calls, then its files and folds) and acts on the
  -- current tab, so the next one opens once it has settled.
  local function open_next(i)
    local target = targets[i]
    if not target then
      if current and vim.api.nvim_tabpage_is_valid(current) then vim.api.nvim_set_current_tabpage(current) end
      return
    end
    if not vim.api.nvim_tabpage_is_valid(target.tab) then return open_next(i + 1) end
    vim.api.nvim_set_current_tabpage(target.tab)
    local diffview = require "diffview"
    if target.view.cmd == "open" then
      diffview.open(target.view.args)
    else
      diffview.file_history(nil, target.view.args)
    end
    local view = require("diffview.lib").get_current_view()
    -- the view opened in a new tab right after the restored one: it takes that tab's place
    if vim.api.nvim_get_current_tabpage() ~= target.tab then
      pcall(vim.cmd.tabclose, vim.api.nvim_tabpage_get_number(target.tab))
    end
    if current == target.tab then current = vim.api.nvim_get_current_tabpage() end
    local waited = 0
    local function settled()
      return not view
        or (view.ready and view.initialized ~= false and not (view.panel and view.panel.updating))
        or waited >= 10000
    end
    local function wait()
      if settled() then
        return vim.defer_fn(function() open_next(i + 1) end, 200)
      end
      waited = waited + 100
      vim.defer_fn(wait, 100)
    end
    wait()
  end
  -- resession calls this with eventignore=all, and diffview needs its autocmds: open the views once the load is done.
  -- Deferred past the other extensions' scheduled work (tab_names reopens plugin tabs and picks the current tab): it
  -- would otherwise run inside diffview's synchronous git calls and change the current tab under the opening view.
  vim.defer_fn(function()
    current = vim.api.nvim_get_current_tabpage()
    open_next(1)
  end, 100)
end

return M
