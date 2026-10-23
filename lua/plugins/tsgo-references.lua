-- `grr` (goto references) on tsgo stops at `export default { fn }` / `module.exports = { fn }`
-- instead of listing the `Obj.fn()` call sites across files. Override it, buffer-locally for tsgo
-- buffers, with a handler that follows the export object (see `lua/utils/tsgo.lua`). Scheduled so it
-- runs after the core/AstroNvim LspAttach that sets the default `grr`, and so wins the mapping.
return {
  "AstroNvim/astrocore",
  opts = {
    autocmds = {
      tsgo_references = {
        {
          event = "LspAttach",
          desc = "Follow export objects for grr (tsgo)",
          callback = function(args)
            local client = vim.lsp.get_client_by_id(args.data.client_id)
            if not client or client.name ~= "tsc" then return end
            vim.schedule(function()
              if not vim.api.nvim_buf_is_valid(args.buf) then return end
              vim.keymap.set("n", "grr", function() require("utils.tsgo").references() end, {
                buffer = args.buf,
                desc = "References (follow exports)",
              })
            end)
          end,
        },
      },
    },
  },
}
