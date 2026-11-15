-- Restart LSP clients when the commit checked out in their project changes: branch switches,
-- and pull/merge/rebase/reset (detected via ORIG_HEAD). Plain commits don't trigger it.
-- One fs watcher per git dir, started lazily on LspAttach. Watches the git dir itself
-- (not the HEAD file) because git replaces HEAD via rename, which kills a file watch.

local M = {}

---@type table<string, { handle: uv.uv_fs_event_t, timer: uv.uv_timer_t, head: string?, toplevel: string }>
local watched = {}
---@type table<string, string|false> root_dir -> git dir (false = not a repo)
local gitdir_cache = {}

-- Commit HEAD points at (nil on an unborn branch) and the reflog subject of how it got there
-- ("commit: ...", "pull: ...", "checkout: ..."). Async: cb runs on the main loop.
local function head_commit(gitdir, cb)
  local cmd = { "git", "--git-dir", gitdir, "log", "-g", "-1", "--format=%H%n%gs", "HEAD" }
  vim.system(cmd, { text = true }, function(res)
    local out = res.code == 0 and vim.split(vim.trim(res.stdout), "\n") or {}
    if out[1] and out[1] ~= "" then
      return vim.schedule(function() cb(out[1], out[2]) end)
    end
    -- no reflog (core.logAllRefUpdates off): fall back to the bare commit
    vim.system({ "git", "--git-dir", gitdir, "rev-parse", "--verify", "-q", "HEAD" }, { text = true }, function(r)
      local sha = r.code == 0 and vim.trim(r.stdout) or nil
      vim.schedule(function() cb(sha) end)
    end)
  end)
end

-- Mid-rebase/bisect HEAD moves on every step; wait until it settles back on a branch.
local function busy(gitdir)
  for _, name in ipairs { "rebase-merge", "rebase-apply", "BISECT_LOG" } do
    if vim.uv.fs_stat(gitdir .. "/" .. name) then return true end
  end
  return false
end

local function restart(toplevel)
  local names = {}
  for _, client in ipairs(vim.lsp.get_clients()) do
    local root = client.root_dir
    if root and (root == toplevel or vim.startswith(root, toplevel .. "/")) then names[client.name] = true end
  end
  if vim.tbl_isempty(names) then return end
  vim.cmd "silent! checktime" -- pick up files the checkout changed before servers re-read them
  for name in pairs(names) do
    vim.cmd("LspRestart " .. name)
  end
end

local function on_change(gitdir)
  local w = watched[gitdir]
  if not w or busy(gitdir) then return end
  head_commit(gitdir, function(head, how)
    if not head or head == w.head or watched[gitdir] ~= w then return end
    w.head = head
    -- your own commit/amend didn't change files on disk; nothing for the servers to re-read
    if how and vim.startswith(how, "commit") then return end
    restart(w.toplevel)
  end)
end

local function watch(gitdir, toplevel)
  if watched[gitdir] then return end
  local handle, timer = vim.uv.new_fs_event(), vim.uv.new_timer()
  if not handle or not timer then return end
  local w = { handle = handle, timer = timer, toplevel = toplevel }
  watched[gitdir] = w
  head_commit(gitdir, function(head) w.head = w.head or head end)
  handle:start(gitdir, {}, function(err, filename)
    -- HEAD: checkout/switch. ORIG_HEAD: pull/merge/rebase/reset move the branch without touching HEAD.
    -- macOS coalesces events and may report only the lock file (e.g. ORIG_HEAD.lock), so match loosely;
    -- the commit comparison in on_change filters out no-ops.
    if err or (filename ~= nil and not filename:find("HEAD", 1, true)) then return end
    -- debounce: a checkout touches HEAD several times (lock, rename)
    timer:stop()
    timer:start(500, 0, vim.schedule_wrap(function() on_change(gitdir) end))
  end)
end

---@param client vim.lsp.Client
function M.attach(client)
  local root = client.root_dir
  if not root then return end
  if gitdir_cache[root] == nil then
    local res = vim.system({ "git", "-C", root, "rev-parse", "--absolute-git-dir", "--show-toplevel" }):wait()
    local out = res.code == 0 and vim.split(vim.trim(res.stdout), "\n") or {}
    gitdir_cache[root] = out[1] or false
    if out[1] and out[2] then watch(out[1], out[2]) end
  end
end

function M.stop_all()
  for gitdir, w in pairs(watched) do
    w.handle:stop()
    w.handle:close()
    w.timer:stop()
    w.timer:close()
    watched[gitdir] = nil
  end
end

return M
