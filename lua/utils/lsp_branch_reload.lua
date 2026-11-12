-- Restart LSP clients when the git branch (HEAD) of their project changes.
-- One fs watcher per git dir, started lazily on LspAttach. Watches the git dir itself
-- (not the HEAD file) because git replaces HEAD via rename, which kills a file watch.

local M = {}

---@type table<string, { handle: uv.uv_fs_event_t, timer: uv.uv_timer_t, head: string?, toplevel: string }>
local watched = {}
---@type table<string, string|false> root_dir -> git dir (false = not a repo)
local gitdir_cache = {}

local function read_head(gitdir)
  local f = io.open(gitdir .. "/HEAD", "r")
  if not f then return nil end
  local head = f:read "*l"
  f:close()
  return head
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
  local head = read_head(gitdir)
  if not head or head == w.head then return end
  w.head = head
  restart(w.toplevel)
end

local function watch(gitdir, toplevel)
  if watched[gitdir] then return end
  local handle, timer = vim.uv.new_fs_event(), vim.uv.new_timer()
  if not handle or not timer then return end
  watched[gitdir] = { handle = handle, timer = timer, head = read_head(gitdir), toplevel = toplevel }
  handle:start(gitdir, {}, function(err, filename)
    if err or (filename ~= "HEAD" and filename ~= nil) then return end
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
