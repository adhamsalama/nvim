-- if true then return {} end -- WARN: REMOVE THIS LINE TO ACTIVATE THIS FILE

-- AstroCore provides a central place to modify mappings, vim options, autocommands, and more!
-- Configuration documentation can be found with `:h astrocore`
-- NOTE: We highly recommend setting up the Lua Language Server (`:LspInstall lua_ls`)
--       as this provides autocomplete and documentation while editing

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
          "<cmd>tabclose<cr>",
          desc = "Close tab",
        },
        ["<Leader>gT"] = false,
        ["<leader>gc"] = false,
        ["<leader>gC"] = false,
        -- tables with just a `desc` key will be registered with which-key if it's installed
        -- this is useful for naming menus
        -- ["<Leader>b"] = { desc = "Buffers" },

        -- setting a mapping to false will disable it
        -- ["<C-S>"] = false,
      },
    },
  },
}
