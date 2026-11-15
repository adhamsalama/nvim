-- Registration snapshot, from what trace_hook.lua (loaded before the config by run.sh) recorded
-- through startup, opening a short and a long JS buffer, and loading lspsaga.
--
-- The raw sequence differs between runs of the same code: LuaJIT seeds string hashing per
-- process, so everything iterated with pairs() (lazy.nvim's handlers, astrocore's autocmd groups
-- and mappings) comes out in a different order each time. So this records what is stable:
--   * the config's own registrations, with counts
--   * the order config modules load in and the config creates namespaces in (namespace ids follow
--     creation order); modules the refactor introduced, and per-client namespaces Neovim creates on
--     first use (`nvim.lsp.codelens:2`, timing-dependent), are left out
-- Registrations by plugins aren't compared here: which of them have happened by a given moment
-- depends on load timing and that random order (wiring.lua compares the resulting final state).
-- Run via tests/lsp/run.sh.

local H = dofile(debug.getinfo(1, "S").source:sub(2):match "^(.*/)" .. "helpers.lua")

H.main(function()
  assert(_G.__lsp_trace, "trace_hook.lua not loaded")
  local small = H.open(H.cases().files.small)
  H.wait_client(small)
  local large = H.open(H.cases().files.large)
  H.wait_client(large)
  vim.wait(3000)
  require("lazy").load { plugins = { "lspsaga.nvim" } }
  local function norm(l)
    l = l:gsub("group=#%d+", "group=#N")
    -- event lists built with pairs(): compare as sets
    local head, ev, rest = l:match "^(nvim_create_autocmd | )(%S+)( .*)$"
    if ev and ev:find "," then
      local list = vim.split(ev, ",")
      table.sort(list)
      l = head .. table.concat(list, ",") .. rest
    end
    return l
  end
  local new_modules = {
    ["lsp.perf.large_buf"] = true,
    ["lsp.functions_picker"] = true,
    ["lsp.tsgo.references"] = true,
    ["lsp.tsgo.builtin_source"] = true,
  }
  local counts, order = {}, {}
  for _, raw in ipairs(_G.__lsp_trace) do
    local l = norm(raw)
    if l:find "| config$" then counts[l] = (counts[l] or 0) + 1 end
    local mod = l:match "^require | (%S+)"
    if
      (mod and not new_modules[mod] and not mod:find "^lsp%.callhierarchy")
      or (l:find "^nvim_create_namespace" and l:find "| config$" and not l:find ":%d+ |")
    then
      order[#order + 1] = l
    end
  end
  local function section(title, lines)
    H.out("## " .. title)
    for _, l in ipairs(lines) do
      H.out("  " .. l)
    end
    H.out ""
  end
  local c = {}
  for l, n in pairs(counts) do
    c[#c + 1] = ("%dx %s"):format(n, l)
  end
  table.sort(c)
  section("config registrations", c)
  section("config module load and namespace order", order)
end)
