-- <Leader>gM: the functions of the current file ranked by how many commits changed them, in a Snacks picker. Each
-- function (as <Leader>af finds them, lua/utils/function_lines.lua) is traced by its lines with `git log -L`, the line
-- history <Leader>gF shows. -L reads line numbers in HEAD, so ranges are mapped from the buffer (unsaved and
-- uncommitted changes) to HEAD's lines first; a function not in HEAD is new.
--
-- -L stops at the commit where all the function's lines appear, as if it was created there. That's also what a move
-- (git's diff deletes the smaller of two swapped blocks and adds it back), a rename with a move, or a move to another
-- file look like. So at that commit, the function it came from is looked for in the parent: one in the same file, or
-- another file the commit changed in the same language, whose lines are at least half the same and which the commit
-- removed (one still there was copied, and a copy doesn't inherit history). Tracing goes on from there, by its lines.

local M = {}

local MAX_JOBS = 8 -- functions traced at once
local MAX_LINKS = 10 -- moves and renames followed per function
local MAX_ORIGIN_FILES = 30 -- other files of a commit searched for where a function came from
local MIN_SIMILARITY = 0.5 -- like git's rename detection (-M50%)
local PROGRESS_ID = "function_churn"

-- Cached for the session, like <Leader>gC's churn. Counts are keyed by the HEAD commit, so a new commit or a checkout
-- counts again: history up to a commit never changes, and neither does anything keyed by a commit below.
local counts = {} ---@type table<string, { count: integer, last_change: integer? }> "<repo>|<HEAD>|<file>|<a>,<b>"
local texts = {} ---@type table<string, string|false> "<repo>|<commit>:<file>" -> the file at that commit, false if none
local commit_files = {} ---@type table<string, string[]> "<repo>|<commit>" -> files the commit changed
local parsed = {} ---@type table<string, FunctionLines[]|false> "<repo>|<commit>:<file>" -> its functions
local waiting = {} ---@type table<string, function[]> callbacks for a git result being fetched

---Runs a git command once per key for the session, calling `cb` with the parsed result.
local function memo_git(cache, key, cmd, cwd, parse, cb)
  if cache[key] ~= nil then return cb(cache[key]) end
  if waiting[key] then return table.insert(waiting[key], cb) end
  waiting[key] = { cb }
  vim.system(cmd, { cwd = cwd, text = true }, function(result)
    vim.schedule(function()
      cache[key] = parse(result)
      local callbacks = waiting[key]
      waiting[key] = nil
      for _, callback in ipairs(callbacks) do
        callback(cache[key])
      end
    end)
  end)
end

---@param cb fun(text: string|false)
local function file_at(repo, commit, file, cb)
  local key = ("%s|%s:%s"):format(repo, commit, file)
  memo_git(
    texts,
    key,
    { "git", "show", commit .. ":" .. file },
    repo,
    function(r) return r.code == 0 and r.stdout end,
    cb
  )
end

---@param cb fun(files: string[])
local function files_changed(repo, commit, cb)
  memo_git(
    commit_files,
    repo .. "|" .. commit,
    { "git", "diff-tree", "--no-commit-id", "--name-only", "-r", commit },
    repo,
    function(r) return r.code == 0 and vim.split(vim.trim(r.stdout), "\n", { trimempty = true }) or {} end,
    cb
  )
end

---@return string? lang the treesitter language of a file name, when its parser is installed
local function lang_of(file)
  local ft = vim.filetype.match { filename = file }
  local lang = ft and vim.treesitter.language.get_lang(ft)
  return lang and pcall(vim.treesitter.language.add, lang) and lang or nil
end

---@param cb fun(functions: FunctionLines[]|false, text: string|false)
local function functions_at(repo, commit, file, cb)
  file_at(repo, commit, file, function(text)
    local key = ("%s|%s:%s"):format(repo, commit, file)
    if text and parsed[key] == nil then
      local lang = lang_of(file)
      parsed[key] = lang and require("utils.function_lines").functions_in_text(text, lang) or false
    end
    cb(text and parsed[key], text)
  end)
end

local function occurrences(text, block)
  local count, from = 0, 1
  while true do
    local at = text:find(block, from, true)
    if not at then return count end
    count, from = count + 1, at + 1
  end
end

---How alike two functions' lines are, 0 to 1: the share of lines they have in common, ignoring indentation and lines
---too short to tell functions apart (`}`, `end`, blank).
local function similarity(a, b)
  local function meaningful(lines)
    local out = {}
    for _, line in ipairs(lines) do
      line = vim.trim(line)
      if #line >= 3 then table.insert(out, line) end
    end
    return out
  end
  a, b = meaningful(a), meaningful(b)
  if #a == 0 or #b == 0 then return 0 end
  local hunks = vim.diff(table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n", { result_type = "indices" })
  local changed = 0
  for _, hunk in ipairs(hunks) do
    changed = changed + hunk[4]
  end
  return 2 * (#b - changed) / (#a + #b)
end

---Where a function whose lines all appear in `commit` came from in `parent`: the function, in its file or another file
---the commit changed, that's most like it (at least MIN_SIMILARITY) and that the commit removed.
---@param lines string[] the function in `commit`
---@param cb fun(origin: { file: string, first: integer, last: integer }?)
local function find_origin(repo, commit, parent, file, lines, cb)
  local lang = lang_of(file)
  if not lang then return cb(nil) end
  files_changed(repo, commit, function(changed)
    local candidates = { file }
    for _, other in ipairs(changed) do
      if #candidates > MAX_ORIGIN_FILES then break end
      if other ~= file and lang_of(other) == lang then table.insert(candidates, other) end
    end
    local own = table.concat(lines, "\n")
    local best, best_score = nil, MIN_SIMILARITY
    local i = 0
    local function next_file()
      i = i + 1
      local candidate = candidates[i]
      if not candidate then return cb(best) end
      functions_at(repo, parent, candidate, function(functions, before)
        if not functions or not before then return next_file() end
        file_at(repo, commit, candidate, function(after)
          local before_lines = vim.split(before, "\n", { plain = true })
          for _, fn in ipairs(functions) do
            local body = vim.list_slice(before_lines, fn.first, fn.last)
            local text = table.concat(body, "\n")
            -- removed by the commit (fewer copies after it, not counting the function itself), so moved or renamed
            local after_count = after and occurrences(after, text) or 0
            if candidate == file and text == own then after_count = after_count - 1 end
            if after_count < occurrences(before, text) then
              local score = similarity(body, lines)
              if score >= best_score and not (best and score == best_score) then
                best, best_score = { file = candidate, first = fn.first, last = fn.last }, score
              end
            end
          end
          next_file()
        end)
      end)
    end
    next_file()
  end)
end

---Commits of `git log -L`, newest first, each with its first parent and the range's lines in it.
---@return { hash: string, time: integer, parent: string?, lines: string[] }[]
local function parse_log(output)
  local commits = {}
  for chunk in vim.gsplit(output, "\1", { plain = true, trimempty = true }) do
    local header, patch = chunk:match "^([^\n]*)\n?(.*)$"
    local hash, time, parents = (header or ""):match "^(%x+) (%d+) ?(.*)$"
    if hash then
      local lines, in_hunk = {}, false
      for line in vim.gsplit(patch, "\n", { plain = true }) do
        if line:match "^@@" then
          in_hunk = true
        elseif line:match "^diff " then
          in_hunk = false
        elseif in_hunk and (line:sub(1, 1) == "+" or line:sub(1, 1) == " ") then
          table.insert(lines, line:sub(2))
        end
      end
      table.insert(commits, {
        hash = hash,
        time = tonumber(time) --[[@as integer]],
        parent = vim.split(parents, " ", { trimempty = true })[1],
        lines = lines,
      })
    end
  end
  return commits
end

---The commit times of a function's history from `rev`, newest first: by its lines, and through its moves and renames.
---@param cb fun(times: integer[]?) nil when git failed
local function trace(repo, rev, file, first, last, depth, cb)
  local range = ("-L%d,%d:%s"):format(first, last, file)
  vim.system({ "git", "log", rev, range, "--format=%x01%H %at %P" }, { cwd = repo, text = true }, function(log)
    vim.schedule(function()
      if log.code ~= 0 then return cb(nil) end
      local commits = parse_log(log.stdout)
      local times = vim.tbl_map(function(c) return c.time end, commits)
      local oldest = commits[#commits]
      if not (oldest and oldest.parent) or depth >= MAX_LINKS then return cb(times) end
      find_origin(repo, oldest.hash, oldest.parent, file, oldest.lines, function(origin)
        if not origin then return cb(times) end
        trace(
          repo,
          oldest.parent,
          origin.file,
          origin.first,
          origin.last,
          depth + 1,
          function(older) cb(vim.list_extend(times, older or {})) end
        )
      end)
    end)
  end)
end

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

  vim.system(
    { "git", "rev-parse", "--show-toplevel", "HEAD" },
    { cwd = dir, text = true },
    vim.schedule_wrap(function(top)
      if top.code ~= 0 then return vim.notify("Not in a git repository", vim.log.levels.WARN) end
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
            trace(toplevel, head_sha, rel, item.head_first, item.head_last, 0, function(times)
              running, done = running - 1, done + 1
              if times then
                item.count, item.last_change = #times, times[1]
                counts[("%s|%d,%d"):format(file_key, item.head_first, item.head_last)] =
                  { count = item.count, last_change = item.last_change }
              end
              if done == total then return finish() end
              if done % 4 == 0 then progress() end
              start_next()
            end)
          end
        end
        if total == 0 then return finish() end
        progress()
        start_next()
      end

      file_at(toplevel, head_sha, rel, function(head_text)
        if not head_text then return vim.notify(rel .. " has no history in HEAD", vim.log.levels.WARN) end
        count_functions(head_text)
      end)
    end)
  )
end

return M
