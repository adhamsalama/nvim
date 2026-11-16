-- Wiring for the custom LSP features in lua/lsp/: every autocmd, command and keymap they add lives
-- here, the logic in the modules. (Server config: astrolsp.lua; call hierarchy: lspsaga.lua.)
--
--   lsp/perf/large_buf      lighter LSP on long files (`vim.b.lsp_lite`)
--   lsp/perf/inlay_range    inlay hints for the visible lines only, one request at a time
--   lsp/perf/slow           warn about / log requests slower than 5s (:LspSlow)
--   lsp/perf/pending        statusline spinner (wired in heirline.lua)
--   lsp/branch_reload       restart clients when the project's git branch changes
--   lsp/functions_picker    pickers limited to named functions and methods
--   lsp/ref_count           reference counts above functions
--   lsp/tsgo/references     `grr`/`grR` that follow export objects (tsgo)
--   lsp/tsgo/builtin_source open the Node source of a built-in module (tsgo)

-- buffer-local keymaps for tsgo (`tsc`) buffers only
local function on_tsgo_attach(callback)
  return function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if not client or client.name ~= "tsc" then return end
    callback(args)
  end
end

---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    local large_buf = require "lsp.perf.large_buf"
    large_buf.setup()
    require("lsp.perf.slow").setup()
    require("lsp.perf.inlay_range").setup()

    opts.autocmds = opts.autocmds or {}
    opts.autocmds.large_buf_lsp = large_buf.autocmds
    opts.autocmds.lsp_branch_reload = {
      {
        event = "LspAttach",
        desc = "Watch the client's git HEAD and restart LSP on branch change",
        callback = function(args)
          local client = vim.lsp.get_client_by_id(args.data.client_id)
          if client then require("lsp.branch_reload").attach(client) end
        end,
      },
      {
        event = "VimLeavePre",
        desc = "Stop git HEAD watchers",
        callback = function() require("lsp.branch_reload").stop_all() end,
      },
    }
    -- `grr` on tsgo stops at `export default { fn }` / `module.exports = { fn }` instead of listing
    -- the `Obj.fn()` call sites across files; replace it with a handler that follows the export
    -- object. Scheduled so it runs after the core/AstroNvim LspAttach that sets the default `grr`,
    -- and so wins the mapping.
    opts.autocmds.tsgo_references = {
      {
        event = "LspAttach",
        desc = "Follow export objects for grr (tsgo)",
        callback = on_tsgo_attach(function(args)
          vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(args.buf) then return end
            vim.keymap.set("n", "grr", function() require("lsp.tsgo.references").references() end, {
              buffer = args.buf,
              desc = "References (scoped to enclosing function on a use)",
            })
            vim.keymap.set("n", "grR", function() require("lsp.tsgo.references").references { all = true } end, {
              buffer = args.buf,
              desc = "References (all, follow exports)",
            })
          end)
        end),
      },
    }
    -- go-to-definition on a Node built-in only reaches its `@types/node` stub
    opts.autocmds.tsgo_builtin_source = {
      {
        event = "LspAttach",
        desc = "Open Node built-in source for the symbol (tsgo)",
        callback = on_tsgo_attach(function(args)
          if not vim.api.nvim_buf_is_valid(args.buf) then return end
          vim.keymap.set(
            "n",
            "<Leader>lN",
            function() require("lsp.tsgo.builtin_source").goto_builtin_source() end,
            { buffer = args.buf, desc = "Node built-in source" }
          )
        end),
      },
    }

    local function picker(name)
      return function() require("lsp.functions_picker")[name]() end
    end
    local function ref_count(name)
      return function() require("lsp.ref_count")[name]() end
    end
    opts.commands = opts.commands or {}
    opts.commands.BufferFunctions = { picker "buffer", desc = "Pick named functions/methods in buffer" }
    opts.commands.WorkspaceFunctions = { picker "workspace", desc = "Pick functions/methods in workspace" }
    opts.commands.RefCountRefresh = { ref_count "refresh", desc = "Refresh LSP reference counts" }
    opts.commands.RefCountDebug = { ref_count "debug", desc = "Debug LSP reference counts" }

    opts.mappings = opts.mappings or {}
    opts.mappings.n = opts.mappings.n or {}
    opts.mappings.n["<Leader>lF"] = { picker "buffer", desc = "LSP Buffer Functions (Named)" }
    opts.mappings.n["<Leader>lt"] = { ref_count "toggle", desc = "Toggle reference counts" }
  end,
}
