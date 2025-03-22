return {
  "ludovicchabant/vim-gutentags", -- Auto-generates CTags
  dependencies = { "nvim-lua/plenary.nvim" }, -- Needed for file operations
  config = function()
    -- Enable Gutentags
    vim.g.gutentags_enabled = 1
    vim.g.gutentags_ctags_executable = "ctags"

    -- Exclude unnecessary directories
    vim.g.gutentags_ctags_extra_args = {
      "--languages=TypeScript,JavaScript",
      "--exclude=node_modules",
      "--exclude=dist",
      "--exclude=build",
      "--exclude=coverage",
      "--exclude=.git",
    }

    -- Set up a keybinding for fast "Go to Definition"
    vim.keymap.set("n", "<Leader>lx", function()
      local word = vim.fn.expand "<cword>"
      vim.cmd("tjump " .. word)
    end, { desc = "Go to JS/TS function definition (CTags)", noremap = true, silent = true })

    -- Auto-update CTags on file save
    vim.api.nvim_create_autocmd("BufWritePost", {
      pattern = { "*.ts", "*.js" },
      command = "silent! !ctags -R --languages=TypeScript,JavaScript --exclude=node_modules",
    })
  end,
}
