-- Copilot-style ghost text from Claude that knows what the Claude Code session in this cwd is doing.
--
-- After a pause in insert mode, the code around the cursor plus the recent turns of the newest Claude
-- Code transcript for this cwd (your prompts, Claude's replies, the edits it made) are sent to
-- `claude -p` with a small model. The reply is shown as virtual text at the cursor and inserted by
-- `accept()` (Tab, through vim.g.ai_accept). It runs on the Claude Code subscription, so no API key is
-- needed, but each request takes ~2.5s. `lua/plugins/claude-ghost.lua` wires this into AstroNvim.

local M = {}

M.config = {
  model = "haiku",
  debounce_ms = 500,
  lines_before = 120, -- buffer lines sent above the cursor
  lines_after = 40, -- and below it
  session_chars = 8000, -- tail of the session excerpt that goes into the prompt
  session_max_age = 6 * 60 * 60, -- ignore transcripts not written to for this many seconds
  max_buf_lines = 5000, -- skip huge buffers
}

local SYSTEM_PROMPT = [[You are a code completion engine inside the user's editor.
The user is typing in the file shown in <file>; <CURSOR> marks the cursor. <session>, when present, is their
recent conversation with a coding agent about this project. The code around the cursor comes first: write the
correct, idiomatic code it calls for, matching names, comments and style there. Use the session only as
background on what the user is working on, for example a plan, API or naming it agreed on.
Reply with only the text to insert at <CURSOR>: real working code, never placeholders. No explanation, no
markdown fences, and never repeat text that is already before or after the cursor. Complete the current line
and, when the intent is clear, up to about 10 following lines. If there is nothing useful to suggest, reply
with nothing.]]

local ns = vim.api.nvim_create_namespace "claude_ghost"
local timer = assert(vim.uv.new_timer())
---@type vim.SystemObj?
local job
local request_id = 0 -- bumped on every request and cancel, so stale replies are dropped
local reported_error = false

-- The suggestion currently shown: inserting `lines` at (row, col) of `buf`, valid while the buffer's
-- changedtick is `tick`.
---@type { buf: integer, row: integer, col: integer, lines: string[], tick: integer }?
local suggestion

-- Off by default: Copilot provides the default ghost text. `toggle()` turns this on.
vim.g.claude_ghost_enabled = vim.g.claude_ghost_enabled == true

local function clear()
  suggestion = nil
  vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
end

local function cancel()
  timer:stop()
  request_id = request_id + 1
  if job then
    job:kill "sigterm"
    job = nil
  end
end

local function render()
  local s = assert(suggestion)
  vim.api.nvim_set_hl(0, "ClaudeGhostText", { link = "Comment", default = true })
  -- Tabs in virtual text don't expand, so render them as spaces.
  local tab = string.rep(" ", vim.bo[s.buf].tabstop)
  local function chunk(line) return { { (line:gsub("\t", tab)), "ClaudeGhostText" } } end
  local virt_lines = {}
  for i = 2, #s.lines do
    virt_lines[#virt_lines + 1] = chunk(s.lines[i])
  end
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(s.buf, ns, s.row, s.col, {
    virt_text = chunk(s.lines[1]),
    virt_text_pos = "inline",
    virt_lines = #virt_lines > 0 and virt_lines or nil,
    hl_mode = "combine",
  })
end

-- The newest transcript of a Claude Code session started in the cwd, with its stat.
local function transcript()
  local dir = vim.fs.joinpath(
    vim.env.CLAUDE_CONFIG_DIR or vim.fs.joinpath(vim.env.HOME, ".claude"),
    "projects",
    (vim.fn.getcwd():gsub("[^%w]", "-"))
  )
  local newest, newest_stat
  local ok = pcall(function()
    for name, type in vim.fs.dir(dir) do
      if type == "file" and name:match "%.jsonl$" then
        local path = vim.fs.joinpath(dir, name)
        local stat = vim.uv.fs_stat(path)
        if stat and (not newest_stat or stat.mtime.sec > newest_stat.mtime.sec) then
          newest, newest_stat = path, stat
        end
      end
    end
  end)
  if ok and newest and os.time() - newest_stat.mtime.sec <= M.config.session_max_age then return newest, newest_stat end
end

local function truncate(text, max) return #text > max and text:sub(1, max) .. " …" or text end

-- Turns an assistant tool call into a line for the excerpt, for the tools that change files.
local function describe_edit(tool)
  local input = tool.input or {}
  if not input.file_path then return end
  local code = tool.name == "Edit" and input.new_string or tool.name == "Write" and input.content
  if tool.name ~= "Edit" and tool.name ~= "Write" and tool.name ~= "MultiEdit" then return end
  return ("Claude edited %s%s"):format(input.file_path, code and ":\n" .. truncate(code, 600) or "")
end

local session_cache = {}

-- Recent conversation of the Claude Code session in this cwd, or nil when there's none.
local function session_context()
  local path, stat = transcript()
  if not path then return end
  if session_cache.path == path and session_cache.mtime == stat.mtime.sec and session_cache.size == stat.size then
    return session_cache.text
  end

  -- Only the end of the transcript matters; skip the partial line where the read starts.
  local file = io.open(path, "rb")
  if not file then return end
  local offset = math.max(0, stat.size - 2 * 1024 * 1024)
  file:seek("set", offset)
  local data = file:read "*a"
  file:close()
  if offset > 0 then data = data:sub((data:find("\n", 1, true) or #data) + 1) end

  local parts = {}
  for line in data:gmatch "[^\n]+" do
    if line:find('"type":"user"', 1, true) or line:find('"type":"assistant"', 1, true) then
      local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      local content = ok
        and type(entry) == "table"
        and not entry.isMeta
        and not entry.isSidechain
        and entry.message
        and entry.message.content
      if type(content) == "string" then content = { { type = "text", text = content } } end
      for _, block in ipairs(type(content) == "table" and content or {}) do
        if block.type == "text" and type(block.text) == "string" and not block.text:match "^%s*<" then
          local who = entry.type == "user" and "User" or "Claude"
          parts[#parts + 1] = ("%s: %s"):format(who, truncate(block.text, 1500))
        elseif block.type == "tool_use" then
          parts[#parts + 1] = describe_edit(block)
        end
      end
    end
  end

  local text = table.concat(parts, "\n\n")
  text = #text > M.config.session_chars and text:sub(-M.config.session_chars) or text
  session_cache = { path = path, mtime = stat.mtime.sec, size = stat.size, text = text ~= "" and text or nil }
  return session_cache.text
end

local function build_prompt(buf, row, col)
  local before = vim.api.nvim_buf_get_lines(buf, math.max(0, row - M.config.lines_before), row, false)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local after = vim.api.nvim_buf_get_lines(buf, row + 1, row + 1 + M.config.lines_after, false)
  before[#before + 1] = line:sub(1, col) .. "<CURSOR>" .. line:sub(col + 1)
  vim.list_extend(before, after)

  local parts = {}
  local session = session_context()
  if session then parts[#parts + 1] = ("<session>\n%s\n</session>"):format(session) end
  parts[#parts + 1] = ('<file path="%s" language="%s">\n%s\n</file>'):format(
    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":."),
    vim.bo[buf].filetype,
    table.concat(before, "\n")
  )
  return table.concat(parts, "\n\n")
end

-- The model's reply as lines to insert, or nil when it has nothing to suggest.
local function parse_reply(text)
  text = text:gsub("^%s*```[%w_+-]*\n", ""):gsub("\n```%s*$", ""):gsub("%s+$", "")
  if text == "" then return end
  return vim.split(text, "\n", { plain = true })
end

local function enabled(buf)
  if not vim.g.claude_ghost_enabled or vim.bo[buf].buftype ~= "" or not vim.bo[buf].modifiable then return false end
  if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"):match "^%.env" then return false end
  return vim.api.nvim_buf_line_count(buf) <= M.config.max_buf_lines
end

local function request()
  local buf = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_get_mode().mode:match "^i" or not enabled(buf) then return end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col, tick = cursor[1] - 1, cursor[2], vim.b[buf].changedtick
  local prompt = build_prompt(buf, row, col)

  cancel()
  local id = request_id
  local cmd = {
    "claude",
    "-p",
    "--model",
    M.config.model,
    "--system-prompt",
    SYSTEM_PROMPT,
    "--tools",
    "",
    "--no-session-persistence",
    "--strict-mcp-config",
    "--setting-sources",
    "",
    "--disable-slash-commands",
  }
  -- Run outside the project so the CLI doesn't pick up its CLAUDE.md; the prompt already has the context.
  local ok, obj = pcall(vim.system, cmd, { stdin = prompt, text = true, cwd = vim.fn.stdpath "cache" }, function(res)
    vim.schedule(function()
      if id ~= request_id then return end -- cancelled or superseded
      job = nil
      if res.code ~= 0 then
        if not reported_error then
          reported_error = true
          vim.notify(
            "Claude ghost text: " .. vim.trim(res.stderr ~= "" and res.stderr or res.stdout),
            vim.log.levels.WARN
          )
        end
        return
      end
      local still_there = vim.api.nvim_get_current_buf() == buf
        and vim.api.nvim_get_mode().mode:match "^i"
        and vim.b[buf].changedtick == tick
        and vim.deep_equal(vim.api.nvim_win_get_cursor(0), cursor)
      local lines = still_there and parse_reply(res.stdout)
      if not lines then return end
      suggestion = { buf = buf, row = row, col = col, lines = lines, tick = tick }
      render()
    end)
  end)
  if ok then
    job = obj
  elseif not reported_error then
    reported_error = true
    vim.notify("Claude ghost text: couldn't run `claude`: " .. obj, vim.log.levels.WARN)
  end
end

local function schedule_request()
  cancel()
  if not vim.g.claude_ghost_enabled then return end
  timer:start(M.config.debounce_ms, 0, vim.schedule_wrap(request))
end

-- TextChangedI: keep the suggestion when the typed text matches its start, otherwise ask for a new one.
function M.on_text_changed()
  local s = suggestion
  local cursor = vim.api.nvim_win_get_cursor(0)
  if s and s.buf == vim.api.nvim_get_current_buf() and cursor[1] - 1 == s.row and cursor[2] > s.col then
    local line = vim.api.nvim_get_current_line()
    local typed = line:sub(s.col + 1, cursor[2])
    if vim.startswith(s.lines[1], typed) and #typed < #s.lines[1] then
      s.lines[1] = s.lines[1]:sub(#typed + 1)
      s.col, s.tick = cursor[2], vim.b.changedtick
      render()
      return
    end
  end
  clear()
  schedule_request()
end

-- CursorMovedI: drop the suggestion when the cursor moves away without typing. Typing also moves the
-- cursor, but changes the changedtick, so that case is left to on_text_changed().
function M.on_cursor_moved()
  local s = suggestion
  if not s or vim.b.changedtick ~= s.tick then return end
  local cursor = vim.api.nvim_win_get_cursor(0)
  if cursor[1] - 1 ~= s.row or cursor[2] ~= s.col then
    cancel()
    clear()
  end
end

function M.on_insert_enter() schedule_request() end

function M.on_insert_leave()
  cancel()
  clear()
end

-- Asks for a suggestion now, skipping the debounce.
function M.trigger()
  clear()
  request()
end

-- Inserts the shown suggestion. Returns true when there was one, for vim.g.ai_accept.
function M.accept()
  local s = suggestion
  if not s or s.buf ~= vim.api.nvim_get_current_buf() or vim.b.changedtick ~= s.tick then return false end
  clear()
  -- Deferred: blink.cmp calls this from an expression mapping, where the buffer can't be changed.
  vim.schedule(function()
    vim.api.nvim_buf_set_text(s.buf, s.row, s.col, s.row, s.col, s.lines)
    local last = s.lines[#s.lines]
    vim.api.nvim_win_set_cursor(0, { s.row + #s.lines, (#s.lines == 1 and s.col or 0) + #last })
  end)
  return true
end

function M.toggle()
  vim.g.claude_ghost_enabled = not vim.g.claude_ghost_enabled
  if not vim.g.claude_ghost_enabled then M.on_insert_leave() end
  vim.notify("Claude ghost text " .. (vim.g.claude_ghost_enabled and "enabled" or "disabled"))
end

return M
