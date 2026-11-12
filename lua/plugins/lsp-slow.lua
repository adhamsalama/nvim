-- Warn about and log LSP requests slower than 5s. Logic lives in `lua/utils/lsp_slow.lua`.

---@type LazySpec
return {
  "AstroNvim/astrocore",
  opts = function() require("utils.lsp_slow").setup() end,
}
