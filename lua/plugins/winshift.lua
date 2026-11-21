-- Rearrange splits: <C-w>m enters move mode (h/j/k/l move the window, H/J/K/L to the far edge, <Esc> to finish),
-- <C-w>X swaps the current window with one picked by letter.

---@type LazySpec
return {
  "sindrets/winshift.nvim",
  cmd = "WinShift",
  keys = {
    { "<C-w>m", "<Cmd>WinShift<CR>", desc = "Move window (WinShift)" },
    { "<C-w>X", "<Cmd>WinShift swap<CR>", desc = "Swap window (WinShift)" },
  },
  opts = {},
}
