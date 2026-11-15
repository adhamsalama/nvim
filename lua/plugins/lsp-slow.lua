-- Warn about and log LSP requests slower than 5s. Logic lives in `lua/lsp/perf/slow.lua`.

---@type LazySpec
return {
  "AstroNvim/astrocore",
  opts = function() require("lsp.perf.slow").setup() end,
}
