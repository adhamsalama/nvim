-- Resession extension that saves and restores the quickfix lists: every list in the stack (:colder / :cnewer, the
-- <Leader>fQ picker) with its title and selected entry, which one is current, and the quickfix windows. Named
-- `quickfix` to replace resession's own extension, which resession always enables and which keeps only the current
-- list's items (and names file-less entries after the current buffer): this module comes first on 'runtimepath'.
-- Registered in `lua/plugins/quickfix.lua`.

local M = {}

-- quickfix item fields to keep; `bufnr` is saved as `filename`, as buffer numbers don't survive a restart
local FIELDS = { "module", "lnum", "end_lnum", "col", "end_col", "vcol", "nr", "pattern", "text", "type", "valid" }

function M.on_save()
  local lists = {}
  for nr = 1, vim.fn.getqflist({ nr = "$" }).nr do
    local list = vim.fn.getqflist { nr = nr, title = 0, items = 0, idx = 0 }
    local items = {}
    for _, item in ipairs(list.items) do
      local saved = { filename = item.bufnr > 0 and vim.api.nvim_buf_get_name(item.bufnr) or nil }
      for _, field in ipairs(FIELDS) do
        saved[field] = item[field]
      end
      table.insert(items, saved)
    end
    table.insert(lists, { title = list.title, idx = list.idx, items = items })
  end
  return { lists = lists, current = vim.fn.getqflist({ nr = 0 }).nr }
end

-- Before the windows load, so a quickfix window opens on the restored list.
function M.on_pre_load(data)
  if vim.islist(data) then -- saved by resession's own extension: the current list's items
    data = { lists = { { title = "", items = data } } }
  end
  if not data.lists then return end
  vim.fn.setqflist({}, "f") -- drop the lists from before the load
  for _, list in ipairs(data.lists) do
    vim.fn.setqflist({}, " ", { title = list.title, items = list.items, idx = list.idx })
  end
  local older = #data.lists - (data.current or #data.lists)
  if older > 0 then vim.cmd("silent colder " .. older) end
end

-- Quickfix windows only: a location list belongs to its window and isn't saved.
function M.is_win_supported(winid, bufnr)
  return vim.bo[bufnr].buftype == "quickfix" and vim.fn.getwininfo(winid)[1].loclist == 0
end

function M.save_win() return {} end

-- Opens the quickfix window at the bottom of the tab (where :copen puts it) in place of the placeholder window.
function M.load_win(winid)
  vim.cmd "botright copen"
  local qf_win = vim.api.nvim_get_current_win()
  if qf_win ~= winid then pcall(vim.api.nvim_win_close, winid, true) end
  return qf_win
end

return M
