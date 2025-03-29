return {
  "lewis6991/gitsigns.nvim",
  opts = {
    current_line_blame = true, -- Enable live line blame
    current_line_blame_opts = {
      virt_text = true,
      virt_text_pos = "eol", -- 'eol' | 'overlay' | 'right_align'
      delay = 0,
      ignore_whitespace = false,
      virt_text_priority = 100,
      use_focus = true,
    },
    on_attach = function(bufnr)
      local gitsigns = require "gitsigns"

      local function map(mode, l, r, opts)
        opts = opts or {}
        opts.buffer = bufnr
        vim.keymap.set(mode, l, r, opts)
      end

      -- Navigation
      map("n", "]g", function()
        if vim.wo.diff then
          vim.cmd.normal { "]c", bang = true }
        else
          gitsigns.nav_hunk "next"
        end
      end, { desc = "Jump to next hunk" })

      map("n", "[g", function()
        if vim.wo.diff then
          vim.cmd.normal { "[c", bang = true }
        else
          gitsigns.nav_hunk "prev"
        end
      end, { desc = "Jump to previous hunk" })

      -- Actions
      map("n", "<leader>gs", gitsigns.stage_hunk, { desc = "Stage hunk" })
      map("n", "<leader>gr", gitsigns.reset_hunk, { desc = "Reset hunk" })

      map(
        "v",
        "<leader>gs",
        function() gitsigns.stage_hunk { vim.fn.line ".", vim.fn.line "v" } end,
        { desc = "Stage selected hunk" }
      )

      map(
        "v",
        "<leader>gr",
        function() gitsigns.reset_hunk { vim.fn.line ".", vim.fn.line "v" } end,
        { desc = "Reset selected hunk" }
      )

      map("n", "<leader>gS", gitsigns.stage_buffer, { desc = "Stage entire buffer" })
      map("n", "<leader>gR", gitsigns.reset_buffer, { desc = "Reset entire buffer" })
      map("n", "<leader>gp", gitsigns.preview_hunk, { desc = "Preview hunk" })
      -- map("n", "<leader>gi", gitsigns.preview_hunk_inline, { desc = "Preview hunk inline" })

      map("n", "<leader>gl", function() gitsigns.blame_line { full = true } end, { desc = "Blame" })
      -- map("n", "<leader>gd", gitsigns.diffthis, { desc = "Diff against index" })

      -- map("n", "<leader>gD", function() gitsigns.diffthis "~" end, { desc = "Diff against last commit" })

      -- map("n", "<leader>gQ", function() gitsigns.setqflist "all" end, { desc = "Add all hunks to quickfix list" })
      -- map("n", "<leader>gq", gitsigns.setqflist, { desc = "Add buffer hunks to quickfix list" })

      -- Toggles
      -- map("n", "<leader>tb", gitsigns.toggle_current_line_blame, { desc = "Toggle current line blame" })
      -- map("n", "<leader>tg", gitsigns.toggle_deleted, { desc = "Toggle deleted lines" })
      -- map("n", "<leader>tw", gitsigns.toggle_word_diff, { desc = "Toggle word diff" })

      -- Text object
      -- map({ "o", "x" }, "ig", gitsigns.select_hunk, { desc = "Select hunk" })
    end,
  },
}
