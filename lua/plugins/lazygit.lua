-- :LazyGit opens lazygit through snacks.nvim (replaces kdheepak/lazygit.nvim)

---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    commands = {
      LazyGit = { function() require("snacks").lazygit() end, desc = "Open lazygit" },
    },
  },
}
