-- Lspsaga, used *only* for its call hierarchy tree.
--
-- Deliberately not using the `astrocommunity.lsp.lspsaga-nvim` pack: that one also remaps
-- `K`, `gd`, rename, code action and the diagnostic jumps over AstroNvim's defaults.
-- Here the plugin stays unloaded until `:Lspsaga` or one of the two keymaps below is used.
--
-- `saga.setup()` only has three load-time side effects (lspsaga/init.lua:203-222):
--   * lightbulb autocmd            -> disabled below
--   * symbol:register_module()     -> runs unconditionally, but every branch inside is gated
--                                     on `symbol_in_winbar.enable` / `implement.enable`
--   * diagnostic_only_current      -> already false by default
-- Everything else in lspsaga is command-triggered, so leaving it unmapped keeps it inert.

---@type LazySpec
return {
  "nvimdev/lspsaga.nvim",
  cmd = "Lspsaga",
  keys = {
    { "<Leader>lc", "<Cmd>Lspsaga incoming_calls<CR>", desc = "Incoming calls" },
    { "<Leader>lC", "<Cmd>Lspsaga outgoing_calls<CR>", desc = "Outgoing calls" },
  },
  opts = {
    -- we have our own winbar (see `lua/plugins/astroui.lua`)
    symbol_in_winbar = { enable = false },
    lightbulb = { enable = false },
    implement = { enable = false },
    beacon = { enable = false },
    callhierarchy = {
      layout = "float",
      keys = {
        edit = "<CR>",
        vsplit = "s",
        split = "i",
        tabe = "t",
        quit = "q",
        close = "<C-c>k",
        shuttle = "[w",
        toggle_or_req = "<Tab>", -- expand a node to request the next level
      },
    },
  },
  config = function(_, opts)
    require("lspsaga").setup(opts)

    -- Preview/jump to the actual call site, the way VS Code does.
    --
    -- For incoming calls the protocol provides `fromRanges` — where inside the caller the call
    -- happens — but lspsaga only ever reads `from.selectionRange`, the caller's declaration
    -- (callhierarchy.lua:248 for the jump, :294 for the preview); `fromRanges` appears nowhere
    -- in the plugin. It does keep the whole result object as the node value, so the ranges are
    -- already in memory, just unused.
    --
    -- So: swap in the call site for display, and restore the declaration on the way back out.
    -- The restore matters — `toggle_or_request` sends the same item back to fetch the next
    -- level, and a rewritten selectionRange would resolve to the wrong symbol and break
    -- expansion. Outgoing calls are left alone: their `fromRanges` are in the *current* file,
    -- not in `to`, so `to.selectionRange` is already correct there.
    local util = require "lspsaga.util"
    local orig_request = util.client_request
    util.client_request = function(client, method, params, handler, ...)
      if type(params) == "table" and type(params.item) == "table" and params.item.__decl_range then
        local item = vim.deepcopy(params.item)
        item.selectionRange, item.__decl_range = item.__decl_range, nil
        params = vim.tbl_extend("force", params, { item = item })
      end
      if method == "callHierarchy/incomingCalls" and type(handler) == "function" then
        local inner = handler
        handler = function(err, res, ...)
          if type(res) == "table" then
            for _, call in ipairs(res) do
              local site = type(call.fromRanges) == "table" and call.fromRanges[1]
              if site and type(call.from) == "table" and not call.from.__decl_range then
                call.from.__decl_range = call.from.selectionRange
                call.from.selectionRange = site
              end
            end
          end
          return inner(err, res, ...)
        end
      end
      return orig_request(client, method, params, handler, ...)
    end
  end,
}
