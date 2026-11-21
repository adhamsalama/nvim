-- claudecode.nvim terminal provider that shows Claude Code either alone in a tab of its own, named "Claude"
-- (`vim.t.name`, like the GitGraph and kubectl tabs), or docked at the bottom of the current tab. One Claude runs, and
-- it shows in one place at a time. Diffs are unaffected: diff.lua opens each in a new tab and docks this provider's
-- terminal buffer there (see the `_setup_blocking_diff` override in lua/plugins/claude.lua).
--
-- toggle_tab / toggle_dock show Claude in that place, or leave it when it's already there. :ClaudeCode (and anything
-- else that opens Claude, like sending a selection) shows it where it was last, the tab at first. Leaving the Claude
-- tab goes back to the tab you came from and keeps the tab open (close it with :tabclose); leaving the dock closes
-- it. Claude keeps running either way.

local M = {}

M.tab_name = "Claude"
M.dock_height = 0.4 -- fraction of the editor height

---@alias ClaudePlace "tab"|"dock"

---@class ClaudeTabState
---@field buf integer?
---@field job integer?
---@field prev_tab integer? the last other tab that was current, to go back to from the Claude tab
---@field config table effective terminal config of the running Claude
---@field place ClaudePlace where Claude shows when opened
---@field place_once ClaudePlace? overrides `place` for the next open
local state = { config = {}, place = "tab" }

local function running(job) return job ~= nil and vim.fn.jobwait({ job }, 0)[1] == -1 end

local function alive() return state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf) and running(state.job) end

---The Claude tab, if it is open.
---@return integer?
function M.tab()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if vim.t[tab].claude_tab then return tab end
  end
end

---@param tab integer? defaults to the current tab
function M.is_claude_tab(tab) return vim.t[tab or vim.api.nvim_get_current_tabpage()].claude_tab == true end

---The tab to go back to from the Claude tab: the one it was entered from, else the first other tab.
---@return integer?
function M.editor_tab()
  if state.prev_tab and vim.api.nvim_tabpage_is_valid(state.prev_tab) and not M.is_claude_tab(state.prev_tab) then
    return state.prev_tab
  end
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if not M.is_claude_tab(tab) then return tab end
  end
end

---@param tab integer
---@return integer? win a window of `tab` that shows the Claude terminal
local function term_win_in(tab)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_buf(win) == state.buf then return win end
  end
end

---@param tab integer? any tab when nil
---@return integer[] wins the bottom docks of Claude (not its window in a diff tab)
local function dock_wins(tab)
  local wins = {}
  for _, win in ipairs(tab and vim.api.nvim_tabpage_list_wins(tab) or vim.api.nvim_list_wins()) do
    if vim.w[win].claude_dock and vim.api.nvim_win_get_buf(win) == state.buf then table.insert(wins, win) end
  end
  return wins
end

local function shown_anywhere() return state.buf ~= nil and vim.fn.win_findbuf(state.buf)[1] ~= nil end

local function start_insert()
  if state.config.auto_insert ~= false and running(state.job) then vim.cmd.startinsert() end
end

---Opens an empty Claude tab after the last tab and makes it current.
local function new_tab()
  vim.cmd "$tabnew"
  vim.bo.bufhidden = "wipe" -- the empty buffer of :tabnew goes once Claude's replaces it
  vim.t.claude_tab = true
  vim.t.name = M.tab_name
  vim.cmd.redrawtabline()
end

---Closes the Claude tab (Claude keeps running unless its buffer goes too), going back to the editor tab when it was
---current.
local function close_tab()
  local tab = M.tab()
  if not tab then return end
  local back = M.editor_tab()
  if not back then
    vim.cmd "tabnew" -- the Claude tab is the only one, and the last tab can't be closed
    back = vim.api.nvim_get_current_tabpage()
  end
  if vim.api.nvim_get_current_tabpage() == tab then vim.api.nvim_set_current_tabpage(back) end
  pcall(vim.cmd.tabclose, vim.api.nvim_tabpage_get_number(tab))
end

---@param tab integer? any tab when nil
local function close_docks(tab)
  for _, win in ipairs(dock_wins(tab)) do
    pcall(vim.api.nvim_win_close, win, false) -- fails only for the last window of the last tab
  end
end

local function forget()
  state.buf, state.job = nil, nil
end

---@param job integer
local function on_exit(job)
  if state.job ~= job then return end -- replaced or closed already
  local buf = state.buf
  local wins = dock_wins()
  forget()
  if state.config.auto_close == false then return end
  close_tab()
  for _, win in ipairs(wins) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
end

---Starts Claude in the current window. On failure the window shows what it showed before.
---@return boolean started
local function start(cmd_string, env_table, config)
  local utils = require "claudecode.utils"
  local before = vim.api.nvim_get_current_buf()
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].bufhidden = "hide" -- Claude keeps running when its window closes
  vim.api.nvim_win_set_buf(0, buf)
  -- parse_command gives an argv list, so no shell expands model aliases like "opus[1m]"
  local ok, job = pcall(vim.fn.jobstart, utils.parse_command(cmd_string), {
    term = true,
    env = env_table,
    cwd = config.cwd,
    on_exit = function(id)
      vim.schedule(function() on_exit(id) end)
    end,
  })
  if not ok or job <= 0 then
    vim.notify("Claude Code failed to start: " .. tostring(job), vim.log.levels.ERROR)
    if vim.api.nvim_buf_is_valid(before) then vim.api.nvim_win_set_buf(0, before) end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return false
  end
  state.buf, state.job, state.config = buf, job, config or {}
  utils.map_terminal_suspend(buf)
  vim.bo[buf].filetype = "claudecode"
  return true
end

---Shows Claude in its tab, opening the tab (and starting Claude when it isn't running). Without focus, the current tab
---stays current.
local function show_tab(focus, cmd_string, env_table, config)
  close_docks()
  local origin = vim.api.nvim_get_current_tabpage()
  local tab = M.tab()
  if not tab then
    new_tab()
    if not alive() then
      if not start(cmd_string, env_table, config) then return close_tab() end
    else
      vim.api.nvim_win_set_buf(0, state.buf)
    end
    tab = vim.api.nvim_get_current_tabpage()
    if not focus then vim.api.nvim_set_current_tabpage(origin) end
  elseif focus and origin ~= tab then
    vim.api.nvim_set_current_tabpage(tab)
  end
  if not focus then return end
  local win = term_win_in(tab)
  if not win then -- something else was opened over it in its tab
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, state.buf)
  end
  vim.api.nvim_set_current_win(win)
  start_insert()
end

---Shows Claude docked at the bottom of the current tab (the editor tab when the Claude tab is current), starting it
---when it isn't running.
local function show_dock(focus, cmd_string, env_table, config)
  close_tab()
  local win = term_win_in(vim.api.nvim_get_current_tabpage())
  if not win then
    local origin = vim.api.nvim_get_current_win()
    vim.cmd("botright " .. math.floor(vim.o.lines * M.dock_height) .. "split")
    win = vim.api.nvim_get_current_win()
    vim.w[win].claude_dock = true
    vim.wo[win].winfixheight = true
    if not alive() then
      if not start(cmd_string, env_table, config) then return pcall(vim.api.nvim_win_close, win, true) end
    else
      vim.api.nvim_win_set_buf(win, state.buf)
    end
    if not focus then vim.api.nvim_set_current_win(origin) end
  end
  if not focus then return end
  vim.api.nvim_set_current_win(win)
  start_insert()
end

---Leaves Claude when it shows in the current tab: goes back from the Claude tab (which stays open), closes a dock.
---@return boolean left
local function hide_here()
  if not alive() then return false end
  if M.is_claude_tab() then
    local back = M.editor_tab()
    if back then
      vim.api.nvim_set_current_tabpage(back)
    else
      vim.cmd "tabnew" -- the Claude tab is the only one
    end
    return true
  end
  local tab = vim.api.nvim_get_current_tabpage()
  if dock_wins(tab)[1] then
    close_docks(tab)
    return true
  end
  return false
end

---@param place ClaudePlace
local function toggle(place)
  local here = place == "tab" and M.is_claude_tab() or (place == "dock" and dock_wins(0)[1] ~= nil)
  if alive() and here then return hide_here() end
  state.place_once = place
  vim.cmd "ClaudeCodeOpen" -- through claudecode, which builds the command and env
end

function M.toggle_tab() toggle "tab" end
function M.toggle_dock() toggle "dock" end

---Goes to the Claude tab when Claude is running and shows in a tab (a dock is already in view, so it's left alone).
function M.focus_tab()
  if alive() and state.place == "tab" then show_tab(true) end
end

-- Provider interface (claudecode.nvim lua/claudecode/terminal/README.md)

function M.setup(config) state.config = config or {} end

function M.is_available() return true end

function M.get_active_bufnr() return alive() and state.buf or nil end

function M.open(cmd_string, env_table, config, focus)
  local place = state.place_once or state.place
  state.place_once, state.place = nil, place
  if not alive() then forget() end
  local show = place == "dock" and show_dock or show_tab
  show(focus ~= false, cmd_string, env_table, config)
end

function M.close()
  local buf, job = state.buf, state.job
  local wins = dock_wins()
  forget()
  if running(job) then vim.fn.jobstop(job) end
  close_tab()
  for _, win in ipairs(wins) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
end

function M.simple_toggle(cmd_string, env_table, config)
  if hide_here() then return end
  M.open(cmd_string, env_table, config, true)
end

-- Like simple_toggle, except where Claude shows in a tab next to other windows (a dock or a diff tab): there it moves
-- between Claude's window and the previous one.
function M.focus_toggle(cmd_string, env_table, config)
  if alive() and not M.is_claude_tab() then
    local win = term_win_in(vim.api.nvim_get_current_tabpage())
    if win == vim.api.nvim_get_current_win() then return vim.cmd "wincmd p" end
    if win then
      vim.api.nvim_set_current_win(win)
      return start_insert()
    end
  end
  M.simple_toggle(cmd_string, env_table, config)
end

M.toggle = M.simple_toggle

-- Called after an @ mention is sent, and when a diff tab closes: shows Claude where it was last, without focus, when
-- it isn't shown anywhere.
function M.ensure_visible()
  if not alive() or shown_anywhere() then return end
  if state.place == "dock" then
    show_dock(false)
  else
    show_tab(false)
  end
end

-- Remember the tab to go back to from the Claude tab, however it was entered (toggle, gt, a click on the tabline).
vim.api.nvim_create_autocmd("TabLeave", {
  group = vim.api.nvim_create_augroup("ClaudeTabPrev", { clear = true }),
  desc = "Remember the tab left for the Claude tab",
  callback = function()
    if not M.is_claude_tab() then state.prev_tab = vim.api.nvim_get_current_tabpage() end
  end,
})

-- Enter terminal mode on entering Claude's window in its tab or dock (as Snacks' auto_insert did). Not in a diff tab:
-- diff.lua handles that window, and an insert queued while it builds the layout would start in a diff window.
vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
  group = vim.api.nvim_create_augroup("ClaudeTabInsert", { clear = true }),
  desc = "Enter terminal mode in the Claude tab or dock",
  callback = function()
    if state.buf and vim.api.nvim_get_current_buf() == state.buf and (M.is_claude_tab() or vim.w.claude_dock) then
      start_insert()
    end
  end,
})

return M
