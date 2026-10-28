-- Go-to-definition on a Node built-in (`zlib`, `fs`, `crypto`, ...) can only reach its `@types/node`
-- `.d.ts` stub; the JS glue that wraps the native bindings lives in the Node source, not on disk.
-- `<Leader>lN` resolves the symbol and opens the matching `lib/<module>.js` from nodejs/node at the
-- running Node version (see `lua/utils/tsgo.lua`). Bound buffer-locally for tsgo (`tsc`) buffers,
-- mirroring `tsgo-references.lua`.
return {
  "AstroNvim/astrocore",
  opts = {
    autocmds = {
      tsgo_builtin_source = {
        {
          event = "LspAttach",
          desc = "Open Node built-in source for the symbol (tsgo)",
          callback = function(args)
            local client = vim.lsp.get_client_by_id(args.data.client_id)
            if not client or client.name ~= "tsc" then return end
            if not vim.api.nvim_buf_is_valid(args.buf) then return end
            vim.keymap.set("n", "<Leader>lN", function() require("utils.tsgo").goto_builtin_source() end, {
              buffer = args.buf,
              desc = "Node built-in source",
            })
          end,
        },
      },
    },
  },
}
