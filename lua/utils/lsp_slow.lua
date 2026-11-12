-- Debug slow LSP requests: anything waiting longer than `threshold_ms` gets a warning while it is
-- still pending and a log entry once it finishes. Each entry records the method, where the cursor
-- was, whether it was cancelled, the server's memory, and what else was in flight at the time
-- (to tell a slow request apart from one queued behind others).
--
-- :LspSlow   open the log        :LspSlow!  clear it

local M = {}

M.threshold_ms = 5000
-- Notifications are batched: flushed once nothing new arrived for `debounce_ms`, or at most
-- `max_wait_ms` after the first one queued, so a burst of slow requests yields one popup.
M.debounce_ms = 1000
M.max_wait_ms = 3000
M.log_path = vim.fn.stdpath "state" .. "/lsp_slow.log"

-- Background requests are logged but don't pop up warnings (same list as the statusline spinner).
local quiet = require("utils.lsp_pending").ignored

---@type table<string, {start: integer, client: string, method: string, file: string, where: string?, cancelled_at: integer?, in_flight: string[], mem: string?, warned: boolean?}>
local reqs = {}

local function ms_since(t) return math.floor((vim.uv.hrtime() - t) / 1e6) end
local function short(method) return (method:gsub("^textDocument/", "")) end

-- Pending requests listed individually; cancelled ones the server hasn't answered yet (tsgo keeps
-- working on them) are summarised per method, e.g. "98 cancelled diagnostic".
local function in_flight(client, self_id)
  local list, cancelled = {}, {}
  for id, req in pairs(client.requests) do
    local r = reqs[client.id .. ":" .. id]
    if id ~= self_id and r then
      if req.type == "cancel" then
        cancelled[short(req.method)] = (cancelled[short(req.method)] or 0) + 1
      else
        table.insert(list, string.format("%s %.1fs", short(req.method), ms_since(r.start) / 1000))
      end
    end
  end
  for method, n in pairs(cancelled) do
    table.insert(list, string.format("%d cancelled %s", n, method))
  end
  return list
end

-- One lookup per client at a time, result reused for `mem_ttl_ms`: a burst of slow requests (e.g.
-- dozens of cancelled diagnostics) would otherwise spawn a shell each and exhaust file descriptors.
M.mem_ttl_ms = 5000
---@type table<integer, {value: string?, at: integer?, waiters: function[]?}>
local mem_cache = {}

-- macOS `ps` RSS is misleading for Go's heap; `footprint` reports what Activity Monitor shows.
---@param client vim.lsp.Client
local function server_mem(client, cb)
  local argv = type(client.config.cmd) == "table" and client.config.cmd or nil
  if not argv then return cb "?" end
  local c = mem_cache[client.id] or {}
  mem_cache[client.id] = c
  if c.waiters then return table.insert(c.waiters, cb) end
  if c.at and ms_since(c.at) < M.mem_ttl_ms then return cb(c.value) end
  c.waiters = { cb }
  local function done(mem)
    local waiters = c.waiters or {}
    c.value, c.at, c.waiters = mem, vim.uv.hrtime(), nil
    for _, w in ipairs(waiters) do
      w(mem)
    end
  end
  -- find nvim's child whose command line contains the server's basename + args (a launcher
  -- may exec a different path), then read its footprint; one async shell, no blocking waits
  local script = [[
for p in $(pgrep -P "$0"); do
  c=$(ps -o command= -p "$p"); ok=1
  for n in "$@"; do case "$c" in *"$n"*) ;; *) ok=0 ;; esac; done
  if [ $ok = 1 ]; then footprint "$p" | sed -n 's/.*Footprint: \([0-9.]* [A-Za-z]*\).*/\1/p' | head -1; exit; fi
done]]
  local cmd = { "sh", "-c", script, tostring(vim.fn.getpid()), vim.fs.basename(argv[1]), unpack(argv, 2) }
  -- vim.system throws synchronously on spawn failure (EMFILE etc.); don't let that break the timer
  local ok = pcall(vim.system, cmd, { text = true }, function(res)
    local mem = vim.trim(res.stdout or "")
    vim.schedule(function() done(mem ~= "" and mem or "?") end)
  end)
  if not ok then done "?" end
end

M.server_mem = server_mem -- exposed for testing

---@type {warn: string[], info: string[], in_flight: string?}
local queued = { warn = {}, info = {} }
local gen, first_at = 0, nil

local function flush()
  local q = queued
  queued, first_at = { warn = {}, info = {} }, nil
  if #q.warn > 0 then
    local title = #q.warn > 1 and (#q.warn .. " slow LSP requests") or "Slow LSP request"
    vim.notify(table.concat(q.warn, "\n") .. "\nin flight: " .. q.in_flight, vim.log.levels.WARN, { title = title })
  end
  if #q.info > 0 then vim.notify(table.concat(q.info, "\n")) end
end

---@param kind "warn"|"info"
local function queue(kind, msg, now_in_flight)
  table.insert(queued[kind], msg)
  if now_in_flight then queued.in_flight = now_in_flight end
  first_at = first_at or vim.uv.hrtime()
  gen = gen + 1
  local my = gen
  local wait = math.max(0, math.min(M.debounce_ms, M.max_wait_ms - ms_since(first_at)))
  vim.defer_fn(function()
    if my == gen then flush() end
  end, wait)
end

local function append(line)
  local f = io.open(M.log_path, "a")
  if f then
    f:write(line, "\n")
    f:close()
  end
end

local function on_request(args)
  local d = args.data
  local client = vim.lsp.get_client_by_id(d.client_id)
  if not client then return end
  local key = d.client_id .. ":" .. d.request_id
  local req = d.request

  if req.type == "pending" then
    local r = {
      start = vim.uv.hrtime(),
      client = client.name,
      method = req.method,
      file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(req.bufnr), ":~:."),
      in_flight = in_flight(client, d.request_id),
    }
    if req.bufnr == vim.api.nvim_get_current_buf() then
      local pos = vim.api.nvim_win_get_cursor(0)
      r.where = string.format("L%d:%d '%s'", pos[1], pos[2] + 1, vim.fn.expand "<cword>")
    end
    reqs[key] = r
    vim.defer_fn(function()
      if reqs[key] ~= r then return end -- already finished
      server_mem(client, function(mem) r.mem = mem end)
      if quiet[r.method] or r.cancelled_at then return end
      r.warned = true
      local now = in_flight(client, d.request_id)
      queue(
        "warn",
        string.format(
          "%s: %s waiting > %ds%s",
          r.client,
          short(r.method),
          M.threshold_ms / 1000,
          r.where and (" at " .. r.where) or ""
        ),
        #now > 0 and table.concat(now, ", ") or "nothing else"
      )
    end, M.threshold_ms)
  elseif req.type == "cancel" then
    if reqs[key] then reqs[key].cancelled_at = vim.uv.hrtime() end
  elseif req.type == "complete" then
    local r = reqs[key]
    reqs[key] = nil
    if not r then return end
    local dur = ms_since(r.start)
    if dur < M.threshold_ms then return end
    local line = string.format(
      "%s  %-5s %-28s %7.1fs  %s%s%s  mem=%s  in-flight-at-send=[%s]",
      os.date "%Y-%m-%d %H:%M:%S",
      r.client,
      short(r.method),
      dur / 1000,
      r.file,
      r.where and (" " .. r.where) or "",
      r.cancelled_at and string.format("  CANCELLED after %.1fs", (r.cancelled_at - r.start) / 1e9) or "",
      r.mem or "?",
      table.concat(r.in_flight, ", ")
    )
    append(line)
    if r.warned then
      queue("info", string.format("%s: %s replied after %.1fs", r.client, short(r.method), dur / 1000))
    end
  end
end

function M.setup()
  vim.api.nvim_create_autocmd("LspRequest", {
    group = vim.api.nvim_create_augroup("lsp_slow_requests", { clear = true }),
    desc = "Log LSP requests slower than the threshold",
    callback = on_request,
  })
  vim.api.nvim_create_user_command("LspSlow", function(cmd)
    if cmd.bang then
      os.remove(M.log_path)
      return vim.notify "LSP slow-request log cleared"
    end
    if vim.fn.filereadable(M.log_path) == 0 then return vim.notify "No slow LSP requests logged" end
    vim.cmd("botright split " .. vim.fn.fnameescape(M.log_path))
    vim.cmd "normal! G"
  end, { bang = true, desc = "Show (or ! clear) the slow LSP request log" })
end

return M
