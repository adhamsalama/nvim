-- Make closing a buffer tab-local.
--
-- AstroNvim's `astrocore.buffer.close` deletes the buffer, and its `BufDelete`
-- autocmd then drops it from every tab's `vim.t.bufs`, so closing a file in one
-- tab also closes it in every other tab that has it open. We wrap `close` so
-- that a buffer still listed in another tab is only removed from the current
-- tab; it is deleted for real only when this is the last tab holding it. Every
-- close path (<Leader>c, the <Leader>bd picker, the tabline close button,
-- close_all/left/right) goes through `close`, so they all pick this up.

local M = {}

---@param bufnr integer
---@return boolean
local function listed_in_other_tab(bufnr)
  local current = vim.api.nvim_get_current_tabpage()
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    if tabpage ~= current and vim.tbl_contains(vim.t[tabpage].bufs or {}, bufnr) then return true end
  end
  return false
end

-- Windows in this tab that show the buffer switch to its neighbor in this tab's buffers (the one to its left, else the
-- next), or a new empty buffer when it's the tab's only one. Never to a buffer of another tab.
---@param bufnr integer
local function replace_in_tab(bufnr)
  local bufs = vim.t.bufs or {}
  local idx = 1
  for i, b in ipairs(bufs) do
    if b == bufnr then idx = i end
  end
  local others = vim.tbl_filter(function(b) return b ~= bufnr and vim.api.nvim_buf_is_valid(b) end, bufs)
  local replacement = others[math.max(idx - 1, 1)]

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(winid) == bufnr then
      if replacement then
        vim.api.nvim_win_set_buf(winid, replacement)
      else
        vim.api.nvim_win_call(winid, vim.cmd.enew)
      end
    end
  end
end

-- Remove a buffer from the current tab only: it leaves the tab's windows and `vim.t.bufs`.
---@param bufnr integer
local function detach(bufnr)
  replace_in_tab(bufnr)
  -- re-read: `enew` may have just added the new empty buffer to this tab
  vim.t.bufs = vim.tbl_filter(function(b) return b ~= bufnr end, vim.t.bufs or {})
  require("astrocore").event "BufsUpdated"
  vim.cmd.redrawtabline()
end

-- Delete listed buffers that no tab holds any more and no window shows. Closing a tab leaves its
-- buffers listed but in no tab's `vim.t.bufs`: hidden from every tabline, yet still in the buffer
-- picker. Modified buffers and running terminals can't be deleted; they move to the current tab
-- instead, so they stay reachable from the tabline.
function M.prune_orphans()
  local held = {}
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    for _, bufnr in ipairs(vim.t[tabpage].bufs or {}) do
      held[bufnr] = true
    end
  end
  local adopted = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[bufnr].buflisted and not held[bufnr] and vim.tbl_isempty(vim.fn.win_findbuf(bufnr)) then
      -- non-forced delete refuses modified buffers and running terminals
      if vim.bo[bufnr].modified or not pcall(vim.api.nvim_buf_delete, bufnr, {}) then
        if vim.api.nvim_buf_is_valid(bufnr) then table.insert(adopted, bufnr) end
      end
    end
  end
  if #adopted > 0 then
    vim.t.bufs = vim.list_extend(vim.t.bufs or {}, adopted)
    require("astrocore").event "BufsUpdated"
    vim.cmd.redrawtabline()
    vim.notify(("Moved %d unsaved buffer(s) from a closed tab into this tab"):format(#adopted), vim.log.levels.WARN)
  end
end

---Moves the current buffer to another tab, chosen in a tab picker (editor tabs, or a new one): it leaves this tab as
---with <Leader>c and shows in that tab's current window (else its first file window, else a split) at the same cursor
---and scroll position.
function M.move_to_tab()
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  if vim.bo[buf].buftype ~= "" then return vim.notify("Only file buffers move between tabs", vim.log.levels.WARN) end
  local view = vim.fn.winsaveview()
  local origin = vim.api.nvim_get_current_tabpage()
  local is_plugin_tab = require("resession.extensions.tab_names").is_plugin_tab
  require("utils.tab_picker").pick {
    title = "Move " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t") .. " to tab",
    exclude = function(tab) return tab == origin or is_plugin_tab(tab) end,
    new_tab = true,
    confirm = function(tab)
      if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_tabpage_is_valid(origin)) then return end
      if tab and not vim.api.nvim_tabpage_is_valid(tab) then return end
      vim.api.nvim_set_current_tabpage(origin)
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
      detach(buf)
      if tab then
        vim.api.nvim_set_current_tabpage(tab)
        local target = vim.api.nvim_get_current_win()
        local function is_file_win(w)
          return vim.api.nvim_win_get_config(w).relative == "" and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == ""
        end
        if not is_file_win(target) then
          target = vim.tbl_filter(is_file_win, vim.api.nvim_tabpage_list_wins(tab))[1]
          if not target then
            vim.cmd "split"
            target = vim.api.nvim_get_current_win()
          end
          vim.api.nvim_set_current_win(target)
        end
        vim.api.nvim_win_set_buf(target, buf)
      else
        vim.cmd("tab sbuffer " .. buf) -- the TabNew handler (lua/plugins/tab-names.lua) puts it before the plugin tabs
        -- the tab opened on the buffer we came from, which it recorded first
        vim.t.bufs = { buf }
        require("astrocore").event "BufsUpdated"
        vim.cmd.redrawtabline()
      end
      vim.fn.winrestview(view)
    end,
  }
end

function M.setup()
  -- every tab close (:q / <C-w>c on its last window, :tabclose, :tabonly, plugins closing their
  -- tab) drops that tab's buffers. Deferred so a burst of closes (:tabonly) prunes once, and so it
  -- never runs mid-session-load, before the astrocore extension has restored each tab's `bufs`.
  local loading, pending = false, false
  local resession = require "resession"
  resession.add_hook("pre_load", function() loading = true end)
  resession.add_hook("post_load", function()
    loading = false
    -- sessions saved before this fix can carry orphans; drop them on load too
    vim.schedule(M.prune_orphans)
  end)
  vim.api.nvim_create_autocmd("TabClosed", {
    group = vim.api.nvim_create_augroup("tab_buffer_prune", { clear = true }),
    desc = "Delete the closed tab's buffers that no other tab holds",
    callback = function()
      if loading or pending then return end
      pending = true
      vim.schedule(function()
        pending = false
        if not loading then M.prune_orphans() end
      end)
    end,
  })

  local buffer = require "astrocore.buffer"
  local close = buffer.close
  buffer.close = function(bufnr, force)
    if not bufnr or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
    if listed_in_other_tab(bufnr) then return detach(bufnr) end
    -- Snacks.bufdelete would show the window's alternate or the most recently used buffer, which can belong to another
    -- tab (after a session load, the last tab's files are the most recently used): pick from this tab first.
    local wins = vim.tbl_filter(
      function(win) return vim.api.nvim_win_get_buf(win) == bufnr end,
      vim.api.nvim_tabpage_list_wins(0)
    )
    replace_in_tab(bufnr)
    close(bufnr, force)
    -- the close was cancelled (an unsaved buffer): show it again
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buflisted then
      for _, win in ipairs(wins) do
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_set_buf(win, bufnr) end
      end
    end
  end
end

return M
