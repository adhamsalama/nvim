return {
  "MagicDuck/grug-far.nvim",
  opts = {
    engines = {
      ripgrep = {
        extraArgs = "--ignore-case",
      },
    },
  },
  cmd = { "GrugFar" },
  config = function()
    require("grug-far").setup {
      showCompactInputs = true,
      showInputsTopPadding = false,
      showInputsBottomPadding = false,
    }
  end,
}
