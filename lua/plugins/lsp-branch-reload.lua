-- Restart LSP clients when their project's git branch changes.
-- Logic lives in `lua/utils/lsp_branch_reload.lua`.

---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@param opts AstroCoreOpts
  opts = function(_, opts)
    opts.autocmds = opts.autocmds or {}
    opts.autocmds.lsp_branch_reload = {
      {
        event = "LspAttach",
        desc = "Watch the client's git HEAD and restart LSP on branch change",
        callback = function(args)
          local client = vim.lsp.get_client_by_id(args.data.client_id)
          if client then require("utils.lsp_branch_reload").attach(client) end
        end,
      },
      {
        event = "VimLeavePre",
        desc = "Stop git HEAD watchers",
        callback = function() require("utils.lsp_branch_reload").stop_all() end,
      },
    }
  end,
}
