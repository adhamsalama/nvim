-- LSP reference counts above functions (toggle with <Leader>lt). Logic lives in `lua/lsp/ref_count.lua`.

---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    commands = {
      RefCountRefresh = { function() require("lsp.ref_count").refresh() end, desc = "Refresh LSP reference counts" },
      RefCountDebug = { function() require("lsp.ref_count").debug() end, desc = "Debug LSP reference counts" },
    },
    mappings = {
      n = {
        ["<Leader>lt"] = { function() require("lsp.ref_count").toggle() end, desc = "Toggle reference counts" },
      },
    },
  },
}
