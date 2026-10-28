-- if true then return {} end -- WARN: REMOVE THIS LINE TO ACTIVATE THIS FILE

-- AstroCore provides a central place to modify mappings, vim options, autocommands, and more!
-- Configuration documentation can be found with `:h astrocore`
-- NOTE: We highly recommend setting up the Lua Language Server (`:LspInstall lua_ls`)
--       as this provides autocomplete and documentation while editing

-- Session cache of each repo's "most frequently changed files", keyed by git root.
-- Computed once per repo on the first <Leader>gC and reused for the rest of the session.
local churn_cache = {}

---@return snacks.picker.finder.Item[]? items, string? err
local function git_churn_items()
  local root = vim.fs.root(0, ".git") or vim.fn.getcwd()
  if churn_cache[root] then return churn_cache[root] end

  local output = vim.fn.systemlist { "git", "-C", root, "log", "--pretty=format:", "--name-only", "--diff-filter=d" }
  if vim.v.shell_error ~= 0 then return nil, "Not a git repository" end

  -- tally how often each path appears across the history
  local counts, order = {}, {}
  for _, file in ipairs(output) do
    if file ~= "" then
      if not counts[file] then table.insert(order, file) end
      counts[file] = (counts[file] or 0) + 1
    end
  end

  -- keep only paths that still exist, most-changed first
  local items = {}
  for _, file in ipairs(order) do
    local path = root .. "/" .. file
    if vim.fn.filereadable(path) == 1 then table.insert(items, { text = file, file = path, count = counts[file] }) end
  end
  table.sort(items, function(a, b) return a.count > b.count end)

  if not vim.tbl_isempty(items) then churn_cache[root] = items end
  return items
end

---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    -- Configure core features of AstroNvim
    features = {
      large_buf = { size = 1024 * 512, lines = 18000 }, -- set global limits for large files for disabling features like treesitter
      autopairs = true, -- enable autopairs at start
      cmp = true, -- enable completion at start
      diagnostics = true, -- diagnostic settings on startup
      highlighturl = true, -- highlight URLs at start
      notifications = true, -- enable notifications at start
    },
    -- Diagnostics configuration (for vim.diagnostics.config({...})) when diagnostics are on
    diagnostics = {
      virtual_text = true,
      underline = true,
    },
    -- vim options can be configured here
    options = {
      opt = { -- vim.opt.<key>
        relativenumber = true, -- sets vim.opt.relativenumber
        number = true, -- sets vim.opt.number
        spell = false, -- sets vim.opt.spell
        signcolumn = "yes", -- sets vim.opt.signcolumn to yes
        wrap = true, -- sets vim.opt.wrap
        quickfixtextfunc = "v:lua.qftextfunc_no_col", -- hide column number in quickfix
      },
      g = { -- vim.g.<key>
        -- configure global vim variables (vim.g)
        -- NOTE: `mapleader` and `maplocalleader` must be set in the AstroNvim opts or before `lazy.setup`
        -- This can be found in the `lua/lazy_setup.lua` file
      },
    },
    -- User commands
    commands = {
      LspRestart = {
        function(event)
          local name = event.args ~= "" and event.args or nil
          local clients = vim.lsp.get_clients(name and { name = name } or nil)
          if #clients == 0 then
            vim.notify(
              name and ("No active LSP client named '" .. name .. "'") or "No active LSP clients",
              vim.log.levels.WARN
            )
            return
          end
          -- remember each client's name and attached buffers so we can re-enable them
          local names = {}
          for _, client in ipairs(clients) do
            names[client.name] = true
          end
          -- stop the clients, then re-enable once they've fully exited
          vim.lsp.stop_client(clients)
          vim.defer_fn(function()
            for client_name in pairs(names) do
              vim.lsp.enable(client_name, false)
              vim.lsp.enable(client_name, true)
            end
            vim.notify("Restarted LSP: " .. table.concat(vim.tbl_keys(names), ", "), vim.log.levels.INFO)
          end, 500)
        end,
        desc = "Restart active LSP clients (all, or a named one)",
        nargs = "?",
        complete = function(arg)
          local names = {}
          for _, client in ipairs(vim.lsp.get_clients()) do
            if client.name:find(arg, 1, true) == 1 then table.insert(names, client.name) end
          end
          return names
        end,
      },
    },
    -- Mappings can be configured through AstroCore as well.
    -- NOTE: keycodes follow the casing in the vimdocs. For example, `<Leader>` must be capitalized
    mappings = {
      -- first key is the mode
      n = {
        -- second key is the lefthand side of the map

        -- navigate buffer tabs
        ["]b"] = { function() require("astrocore.buffer").nav(vim.v.count1) end, desc = "Next buffer" },
        ["[b"] = { function() require("astrocore.buffer").nav(-vim.v.count1) end, desc = "Previous buffer" },

        -- reorder buffer tabs (move the current buffer along the tabline)
        [">b"] = { function() require("astrocore.buffer").move(vim.v.count1) end, desc = "Move buffer right" },
        ["<b"] = { function() require("astrocore.buffer").move(-vim.v.count1) end, desc = "Move buffer left" },

        -- mappings seen under group name "Buffer"
        ["<Leader>bd"] = {
          function()
            require("astroui.status.heirline").buffer_picker(
              function(bufnr) require("astrocore.buffer").close(bufnr) end
            )
          end,
          desc = "Close buffer from tabline",
        },
        ["<Leader>bt"] = {
          "<Nop>",
          desc = "Tabs",
        },
        ["<Leader>btn"] = {
          "<cmd>tabnew<cr>",
          desc = "Create new tab",
        },
        ["<Leader>btc"] = {
          function()
            if #vim.api.nvim_list_tabpages() == 1 then
              vim.notify("Cannot close the last tab", vim.log.levels.WARN)
              return
            end
            local tab_bufs = vim.t.bufs or {}
            vim.cmd.tabclose()

            -- only wipe buffers that no remaining tab still lists or displays
            local kept = {}
            for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
              for _, bufnr in ipairs(vim.t[tabpage].bufs or {}) do
                kept[bufnr] = true
              end
            end
            local skipped = 0
            for _, bufnr in ipairs(tab_bufs) do
              if
                vim.api.nvim_buf_is_valid(bufnr)
                and not kept[bufnr]
                and vim.tbl_isempty(vim.fn.win_findbuf(bufnr))
              then
                -- non-forced delete refuses modified buffers and running terminals
                if vim.bo[bufnr].modified or not pcall(vim.api.nvim_buf_delete, bufnr, {}) then
                  skipped = skipped + 1
                end
              end
            end
            if skipped > 0 then
              vim.notify(("Kept %d unsaved buffer(s) from the closed tab"):format(skipped), vim.log.levels.WARN)
            end
          end,
          desc = "Close tab and its buffers",
        },
        ["<Leader>gT"] = false,
        ["<leader>gc"] = false,
        ["<Leader>gC"] = {
          function()
            local items, err = git_churn_items()
            if err then
              vim.notify(err, vim.log.levels.ERROR)
              return
            end
            if not items or vim.tbl_isempty(items) then
              vim.notify("No changed files found", vim.log.levels.WARN)
              return
            end

            local width = #tostring(items[1].count)
            require("snacks").picker.pick {
              source = "git_churn",
              title = "Most Frequently Changed Files",
              items = items,
              -- keep the churn order even while filtering, instead of sorting by match score
              sort = function(a, b) return a.count > b.count end,
              format = function(item)
                return {
                  { string.format("%" .. width .. "d", item.count), "Number" },
                  { "  " },
                  { vim.fn.fnamemodify(item.file, ":."), "SnacksPickerFile" },
                }
              end,
              preview = "file",
              confirm = function(picker, item)
                picker:close()
                if item then vim.cmd.edit(vim.fn.fnameescape(item.file)) end
              end,
            }
          end,
          desc = "Churn (most changed files)",
        },
        -- tables with just a `desc` key will be registered with which-key if it's installed
        -- this is useful for naming menus
        -- ["<Leader>b"] = { desc = "Buffers" },

        -- setting a mapping to false will disable it
        -- ["<C-S>"] = false,
      },
    },
  },
}
