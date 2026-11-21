-- Resession extension that saves and restores tab names (`vim.t.name`, set by
-- `lua/plugins/tab-names.lua`). Registered in that file's resession spec.
--
-- It also brings back the plugin tabs a session can't restore by itself: the GitGraph workspace (reopened) and
-- Claude (restarted with `--continue`, in its tab or docked where it was).

local M = {}

local GITGRAPH_TAB = "GitGraph" -- gitgraph.nvim's default `tab_name`

-- Names of the tabs plugins open (`vim.t.name`); every other tab is an editor tab.
M.plugin_tabs = { [GITGRAPH_TAB] = true, DB = true, kubectl = true, HTTP = true, Claude = true }

---@param opts resession.Extension.OnSaveOpts
function M.on_save(opts)
  -- a tab-scoped session only holds its own tab
  if opts.tabpage then return { tab_scoped = true, names = { vim.t[opts.tabpage].name or vim.NIL } } end
  local names, claude_dock_tab = {}, nil
  for i, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    names[i] = vim.t[tabpage].name or vim.NIL -- keep positions aligned for unnamed tabs
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
      if vim.w[win].claude_dock then claude_dock_tab = i end
    end
  end
  local place = require("utils.claude_tab").running_place()
  local claude = place and { place = place, tab = place == "dock" and claude_dock_tab or nil } or nil
  return { names = names, claude = claude }
end

---Runs `fn` with `tab` current, then goes back to the tab that was current.
local function in_tab(tab, fn)
  local current = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_set_current_tabpage(tab)
  pcall(fn)
  if vim.api.nvim_tabpage_is_valid(current) then vim.api.nvim_set_current_tabpage(current) end
end

---@param tab integer
local function is_editor_tab(tab) return vim.api.nvim_tabpage_is_valid(tab) and not M.plugin_tabs[vim.t[tab].name or ""] end

function M.on_post_load(data)
  local tabpages = vim.api.nvim_list_tabpages()
  if data.tab_scoped then tabpages = { vim.api.nvim_get_current_tabpage() } end
  -- The Claude tab holds only Claude's terminal and the GitGraph tab's panels are scratch buffers, so a session brings
  -- both back empty: drop them, then restart Claude and reopen the workspace.
  local claude_tab = require "utils.claude_tab"
  local current = vim.api.nvim_get_current_tabpage()
  local empty, gitgraph = {}, false
  for i, name in ipairs(data.names) do
    if tabpages[i] and name == claude_tab.tab_name then
      table.insert(empty, tabpages[i])
    elseif tabpages[i] and name == GITGRAPH_TAB then
      table.insert(empty, tabpages[i])
      gitgraph = true
    elseif tabpages[i] and type(name) == "string" then
      vim.t[tabpages[i]].name = name
    end
  end
  vim.cmd.redrawtabline()

  -- resession calls this with eventignore=all, so plugins opened now would miss their autocmds (TermOpen turning off
  -- line numbers in Claude's terminal, FileType keymaps, ...): reopen them once the load is done.
  vim.schedule(function()
    -- plugin tabs open from the last tab, so they land at the end where plugin tabs live
    local function last_tab()
      local all = vim.api.nvim_list_tabpages()
      return all[#all]
    end
    if gitgraph then in_tab(last_tab(), function() require("gitgraph.workspace").open() end) end
    local claude = data.claude
    if claude and claude.place == "tab" then
      in_tab(last_tab(), function() claude_tab.resume "tab" end)
    elseif claude and claude.place == "dock" then
      local tab = tabpages[claude.tab]
      in_tab(tab and vim.api.nvim_tabpage_is_valid(tab) and tab or current, function() claude_tab.resume "dock" end)
    end
    for _, tab in ipairs(empty) do
      if vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
        pcall(vim.cmd.tabclose, vim.api.nvim_tabpage_get_number(tab))
      end
    end
    -- focus goes to an editor tab (the one that was current, else the first); plugin tabs only when there's no other
    if not is_editor_tab(current) then
      current = vim.tbl_filter(is_editor_tab, vim.api.nvim_list_tabpages())[1] or current
    end
    if vim.api.nvim_tabpage_is_valid(current) then vim.api.nvim_set_current_tabpage(current) end
    vim.cmd.redrawtabline()
  end)
end

return M
