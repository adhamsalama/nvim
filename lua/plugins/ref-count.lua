-- LSP reference counts above functions (toggle with <Leader>lt). Logic lives in `lua/utils/ref_count.lua`.

---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    commands = {
      RefCountRefresh = { function() require("utils.ref_count").refresh() end, desc = "Refresh LSP reference counts" },
      RefCountDebug = { function() require("utils.ref_count").debug() end, desc = "Debug LSP reference counts" },
    },
    mappings = {
      n = {
        ["<Leader>lt"] = { function() require("utils.ref_count").toggle() end, desc = "Toggle reference counts" },
      },
    },
  },
}
