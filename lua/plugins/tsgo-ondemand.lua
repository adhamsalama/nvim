-- On-demand tsgo features (see `lua/utils/tsgo_ondemand.lua`), bound buffer-locally for tsgo
-- (`tsc`) buffers, mirroring `tsgo-references.lua`.
return {
  "AstroNvim/astrocore",
  opts = {
    autocmds = {
      tsgo_ondemand = {
        {
          event = "LspAttach",
          desc = "On-demand tsgo keymaps",
          callback = function(args)
            local client = vim.lsp.get_client_by_id(args.data.client_id)
            if not client or client.name ~= "tsc" then return end
            local map = function(lhs, fn, desc) vim.keymap.set("n", lhs, fn, { buffer = args.buf, desc = desc }) end
            map(
              "<Leader>lH",
              function() require("utils.tsgo_ondemand").function_hints() end,
              "Toggle inlay hints (function)"
            )
            map(
              "<Leader>lT",
              function() require("utils.tsgo_ondemand").toggle_check() end,
              "Toggle type checking (file)"
            )
          end,
        },
      },
    },
  },
}
