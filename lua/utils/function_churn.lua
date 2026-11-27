-- <Leader>gM: the functions of the current file ranked by how many commits changed them, in a Snacks picker. Each
-- function (as <Leader>af finds them, lua/utils/function_lines.lua) gets its own `git log -L`, the line history
-- <Leader>gF shows, so a function's count follows it as it moves in the file. -L reads line numbers in HEAD, so ranges
-- are mapped from the buffer (unsaved and uncommitted changes) to HEAD's lines first; a function not in HEAD is new.

local M = {}

local MAX_JOBS = 8 -- git processes at once
local PROGRESS_ID = "function_churn"

-- Cached for the session, like <Leader>gC's churn. Keyed by the HEAD commit, so a new commit or a checkout counts again:
-- history up to a commit never changes.
local counts = {} ---@type table<string, { count: integer, last_change: integer? }> "<repo>|<HEAD>|<file>|<a>,<b>"
local head_texts = {} ---@type table<string, string> "<repo>|<HEAD>|<file>" -> the file in HEAD

---@class FunctionChurnItem
---@field name string
---@field first integer buffer lines, 1-indexed
---@field last integer
---@field head_first? integer HEAD lines; nil when the function isn't in HEAD
---@field head_last? integer
---@field count? integer commits; nil when git failed
---@field last_change? integer unix time of the newest commit

---Maps buffer lines to HEAD's from the diff of HEAD's text to the buffer's.
---@return fun(line: integer): integer? head_line nil for a line that isn't in HEAD
local function head_line_mapper(head_text, buf_text)
  local hunks = vim.diff(head_text, buf_text, { result_type = "indices" }) --[[@as integer[][] ]]
  return function(line)
    local offset = 0
    for _, hunk in ipairs(hunks) do
      local a, a_count, b, b_count = unpack(hunk)
      if b_count > 0 and line >= b and line < b + b_count then -- a line the diff changed or added
        if a_count == 0 then return nil end
        return a + math.min(line - b, a_count - 1)
      end
      -- with a count of 0, a hunk's start is the line it comes after
      local after = b_count > 0 and line >= b + b_count or b_count == 0 and line > b
      if not after then break end
      offset = offset + a_count - b_count
    end
    return line + offset
  end
end

---The HEAD lines of a buffer range: its first and last lines that are in HEAD.
---@return integer? first, integer? last
local function head_range(map, first, last)
  local head_first, head_last
  for line = first, last do
    head_first = map(line)
    if head_first then break end
  end
  for line = last, first, -1 do
    head_last = map(line)
    if head_last then break end
  end
  if head_first and head_last and head_last >= head_first then return head_first, head_last end
end

local function reltime(time)
  local ok, util = pcall(require, "snacks.picker.util")
  if ok and util.reltime then return util.reltime(time) end
  return os.date("%Y-%m-%d", time) --[[@as string]]
end

---@param items FunctionChurnItem[]
local function show(items, file, bufnr, note)
  table.sort(items, function(a, b)
    if (a.count or -1) ~= (b.count or -1) then return (a.count or -1) > (b.count or -1) end
    if (a.last_change or 0) ~= (b.last_change or 0) then return (a.last_change or 0) > (b.last_change or 0) end
    return a.first < b.first
  end)
  local width, name_width = 1, 1
  for i, item in ipairs(items) do
    item.text, item.file, item.buf = item.name, file, bufnr
    item.pos, item.end_pos = { item.first, 0 }, { item.last, 0 }
    item.idx = i
    width = math.max(width, #tostring(item.count or "?"))
    name_width = math.max(name_width, vim.api.nvim_strwidth(item.name))
  end
  name_width = math.min(name_width, 40)

  ---@param item FunctionChurnItem
  local function jump(item)
    pcall(vim.api.nvim_win_set_cursor, 0, { item.first, 0 })
    vim.cmd "normal! zvzz"
  end

  Snacks.picker.pick {
    source = "function_churn",
    title = ("Most Changed Functions: %s%s"):format(vim.fn.fnamemodify(file, ":t"), note or ""),
    items = items,
    -- keep the churn order while filtering, instead of sorting by match score
    sort = function(a, b) return a.idx < b.idx end,
    format = function(item)
      local count = item.head_first and tostring(item.count or "?") or "new"
      local name = vim.fn.strcharpart(item.name, 0, name_width)
      return {
        { ("%" .. math.max(width, 3) .. "s"):format(count), item.head_first and "Number" or "DiagnosticHint" },
        { "  " },
        { name .. string.rep(" ", name_width - vim.api.nvim_strwidth(name)), "SnacksPickerLabel" },
        { "  " },
        { item.last_change and reltime(item.last_change) or "", "Comment" },
        { ("  L%d-%d"):format(item.first, item.last), "SnacksPickerComment" },
      }
    end,
    preview = "file",
    confirm = function(picker, item)
      picker:close()
      if item then jump(item) end
    end,
    actions = {
      ---<C-l>: the function's commits in Diffview (as <Leader>gF)
      history = function(picker, item)
        if not item then return end
        if not item.head_first then return vim.notify(item.name .. " isn't in HEAD yet", vim.log.levels.WARN) end
        picker:close()
        jump(item)
        require("diffview").file_history({ item.head_first, item.head_last }, {})
      end,
    },
    win = {
      input = { keys = { ["<C-l>"] = { "history", mode = { "n", "i" }, desc = "Function history" } } },
      list = { keys = { ["<C-l>"] = { "history", desc = "Function history" } } },
    },
  }
end

function M.pick()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" or vim.bo[bufnr].buftype ~= "" then return vim.notify("Not a file", vim.log.levels.WARN) end
  local functions = require("utils.function_lines").functions(bufnr)
  if #functions == 0 then return vim.notify("No functions found", vim.log.levels.WARN) end
  local buf_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n") .. "\n"
  local dir = vim.fs.dirname(file)

  vim.system({ "git", "rev-parse", "--show-toplevel", "HEAD" }, { cwd = dir, text = true }, function(top)
    if top.code ~= 0 then
      return vim.schedule(function() vim.notify("Not in a git repository", vim.log.levels.WARN) end)
    end
    local toplevel, head_sha = unpack(vim.split(vim.trim(top.stdout), "\n"))
    local rel = vim.fs.relpath(toplevel, vim.fs.normalize(vim.uv.fs_realpath(file) or file)) or file
    local file_key = table.concat({ toplevel, head_sha, rel }, "|")

    local function count_functions(head_text)
      local changed = head_text ~= buf_text
      local map = head_line_mapper(head_text, buf_text)
      local items, queue = {}, {} ---@type FunctionChurnItem[], FunctionChurnItem[]
      for _, fn in ipairs(functions) do
        local item = { name = fn.name, first = fn.first, last = fn.last } ---@type FunctionChurnItem
        item.head_first, item.head_last = head_range(map, fn.first, fn.last)
        table.insert(items, item)
        if item.head_first then
          local cached = counts[("%s|%d,%d"):format(file_key, item.head_first, item.head_last)]
          if cached then
            item.count, item.last_change = cached.count, cached.last_change
          else
            table.insert(queue, item)
          end
        end
      end
      local total, done, running = #queue, 0, 0
      local note = changed and " (uncommitted changes mapped to HEAD)" or nil
      local function progress()
        vim.notify(("Counting commits: %d/%d functions"):format(done, total), vim.log.levels.INFO, {
          id = PROGRESS_ID,
          title = "Most Changed Functions",
        })
      end
      local function finish()
        pcall(function() Snacks.notifier.hide(PROGRESS_ID) end)
        show(items, file, bufnr, note)
      end
      local function start_next()
        while running < MAX_JOBS and #queue > 0 do
          local item = table.remove(queue, 1)
          running = running + 1
          local range = ("-L%d,%d:%s"):format(item.head_first, item.head_last, rel)
          vim.system(
            { "git", "log", head_sha, range, "--format=%at", "--no-patch" },
            { cwd = toplevel, text = true },
            function(log)
              vim.schedule(function()
                running, done = running - 1, done + 1
                if log.code == 0 then
                  local times = vim.tbl_map(tonumber, vim.split(vim.trim(log.stdout), "\n", { trimempty = true }))
                  item.count, item.last_change = #times, times[1]
                  counts[("%s|%d,%d"):format(file_key, item.head_first, item.head_last)] =
                    { count = item.count, last_change = item.last_change }
                end
                if done == total then return finish() end
                if done % 4 == 0 then progress() end
                start_next()
              end)
            end
          )
        end
      end
      if total == 0 then return finish() end
      progress()
      start_next()
    end

    if head_texts[file_key] then
      return vim.schedule(function() count_functions(head_texts[file_key]) end)
    end
    vim.system({ "git", "show", head_sha .. ":" .. rel }, { cwd = toplevel, text = true }, function(head)
      vim.schedule(function()
        if head.code ~= 0 then return vim.notify(rel .. " has no history in HEAD", vim.log.levels.WARN) end
        head_texts[file_key] = head.stdout
        count_functions(head.stdout)
      end)
    end)
  end)
end

return M
