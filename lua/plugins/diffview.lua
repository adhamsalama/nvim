return {
  "sindrets/diffview.nvim",
  keys = {
    -- { "<leader>gd", "<Nop>", desc = "Diffview" },
    { "<leader>gd", "<cmd>DiffviewOpen --imply-local<cr>", desc = "Diff" },
    { "<leader>gf", "<cmd>DiffviewFileHistory %<cr>", desc = "File History" },
    { "<leader>gh", "<cmd>DiffviewFileHistory<cr>", desc = "Repo History" },
    { "<leader>gt", "<cmd>DiffviewFileHistory -g --range=stash<cr>", desc = "View Stash" },
    -- { "<leader>gdm", "<cmd>DiffviewOpen origin/HEAD...HEAD --imply-local<cr>", desc = "Review" },
    {
      "<leader>gD",
      function()
        vim.ui.input({ prompt = "Enter branch to compare (leave empty for origin/HEAD): " }, function(branch)
          local target = (branch and branch ~= "") and ("origin/" .. branch) or "origin/HEAD"
          vim.cmd("DiffviewOpen " .. target .. "...HEAD --imply-local")
        end)
      end,
      desc = "Diff branch",
    },
    {
      "<leader>gc",
      function()
        -- Run `git blame` on the current line and extract the commit hash
        local line_num = vim.fn.line "." -- Get the current line number
        local file_path = vim.fn.expand "%" -- Get the current file path
        local blame_output = vim.fn.system("git blame -L " .. line_num .. "," .. line_num .. " " .. file_path)

        -- Extract the commit hash (first word of blame output)
        local commit_hash = blame_output:match "^(%x+)"

        -- Handle cases where no valid commit hash is found
        if not commit_hash or string.find("00000000000000", commit_hash) then
          vim.notify("Not committed", vim.log.levels.INFO)
          return
        end

        vim.cmd("DiffviewFileHistory --range=" .. commit_hash .. "^!") -- This one works
        -- local commit_hash = vim.fn.expand "<cword>"
        -- vim.cmd("DiffviewOpen " .. commit_hash .. "^!")
        -- vim.cmd("DiffviewFileHistory -r " .. commit_hash .. "^!" .. " " .. file_path)
        -- vim.cmd("DiffviewFileHistory --range=" .. commit_hash .. " -1 " .. file_path)
      end,
      desc = "Diff commit of line",
    },
  },
  opts = function(_, opts)
    local actions = require "diffview.actions"

    opts.enhanced_diff_hl = true
    opts.diff_opts = {
      algorithm = "histogram",
      indent_heuristic = true,
      linematch = 60,
    }

    -- Apply to Neovim's internal diff engine (used for rendering)
    vim.opt.diffopt:append "algorithm:histogram"
    vim.opt.diffopt:append "indent-heuristic"
    vim.opt.diffopt:append "linematch:60"

    -- Blend fg color into bg at given alpha (0.0 = all bg, 1.0 = all fg)
    local function blend(fg_hex, bg_hex, alpha)
      local function parse(hex)
        return tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
      end
      local fr, fg, fb = parse(fg_hex)
      local br, bg_r, bb = parse(bg_hex)
      return string.format(
        "#%02x%02x%02x",
        math.floor(fr * alpha + br * (1 - alpha) + 0.5),
        math.floor(fg * alpha + bg_r * (1 - alpha) + 0.5),
        math.floor(fb * alpha + bb * (1 - alpha) + 0.5)
      )
    end

    local function get_hl(group, attr)
      local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
      if not ok or not hl[attr] then return nil end
      return string.format("#%06x", hl[attr])
    end

    local function set_diff_colors()
      local normal_bg = get_hl("Normal", "bg") or "#272e33"
      local blue_fg = get_hl("DiagnosticInfo", "fg") or "#7fbbb3"
      vim.api.nvim_set_hl(0, "DiffChange", { bg = blend(blue_fg, normal_bg, 0.20) })
      vim.api.nvim_set_hl(0, "DiffText", { bg = blend(blue_fg, normal_bg, 0.38), bold = true })
    end

    vim.api.nvim_create_autocmd("ColorScheme", { pattern = "*", callback = set_diff_colors })
    set_diff_colors()

    opts.keymaps = {
      view = {
        ["<leader>b"] = false, -- Focus files panel in Diffview
        { "n", "<leader>e", actions.toggle_files, { desc = "Toggle the file panel." } },
        -- ["<leader>e"] = actions.toggle_files, -- Focus files panel in Diffview
      },
      file_panel = {
        ["<leader>b"] = false, -- Focus files panel in Diffview
        { "n", "<leader>e", actions.toggle_files, { desc = "Toggle the file panel." } },
        -- ["<leader>e"] = actions.toggle_files,
      },
      file_history_panel = {
        ["<leader>b"] = false, -- Focus files panel in Diffview
        { "n", "<leader>e", actions.toggle_files, { desc = "Toggle the file panel." } },
        -- ["<leader>e"] = actions.toggle_files,
        {
          "n",
          "gd",
          function()
            -- Extract commit hash from current line in file history panel
            -- Format: M | 0      1 | b4d22d45 Merge branch...
            local line = vim.fn.getline "."
            -- Match the commit hash after the second pipe: | ... | HASH
            local commit_hash = line:match "|%s*[%w%s]*|%s*(%x+)"
            if commit_hash and #commit_hash >= 7 then
              vim.cmd("DiffviewOpen " .. commit_hash .. "^!")
            else
              vim.notify("Could not find commit hash on this line", vim.log.levels.WARN)
            end
          end,
          { desc = "Open commit in diffview" },
        },
      },
      diff1 = {
        ["<leader>b"] = false, -- Focus files panel in Diffview
        { "n", "<leader>e", actions.toggle_files, { desc = "Toggle the file panel." } },
        -- ["<leader>e"] = actions.toggle_files, -- Focus files panel in Diffview

        {
          "n",
          "<leader>gmO",
          function() actions.conflict_choose "ours" end,
          { desc = "Choose OURS version (merge)" },
        },
        {
          "n",
          "<leader>gmT",
          function()
            vim.notify("Choose THEIRS version (merge)", vim.log.levels.INFO)
            actions.conflict_choose "theirs"()
          end,
          { desc = "Choose THEIRS version (merge)" },
        },
        {
          "n",
          "<leader>gmB",
          function() actions.conflict_choose "base" end,
          { desc = "Choose BASE version (merge)" },
        },
      },
      diff2 = {
        ["<leader>b"] = false, -- Focus files panel in Diffview
        { "n", "<leader>e", actions.toggle_files, { desc = "Toggle the file panel." } },
        -- ["<leader>e"] = actions.toggle_files, -- Focus files panel in Diffview

        {
          "n",
          "<leader>gmO",
          function() actions.conflict_choose "ours" end,
          { desc = "Choose OURS version (merge)" },
        },
        {
          "n",
          "<leader>gmT",
          function()
            vim.notify("Choose THEIRS version (merge)", vim.log.levels.INFO)
            actions.conflict_choose "theirs"()
          end,
          { desc = "Choose THEIRS version (merge)" },
        },
        {
          "n",
          "<leader>gmB",
          function() actions.conflict_choose "base" end,
          { desc = "Choose BASE version (merge)" },
        },
      },
      diff3 = {
        ["<leader>b"] = false, -- Focus files panel in Diffview
        { "n", "<leader>e", actions.toggle_files, { desc = "Toggle the file panel." } },
        -- ["<leader>e"] = actions.toggle_files, -- Focus files panel in Diffview

        {
          "n",
          "<leader>gmO",
          function() actions.conflict_choose "ours" end,
          { desc = "Choose OURS version (merge)" },
        },
        {
          "n",
          "<leader>gmT",
          function()
            vim.notify("Choose THEIRS version (merge)", vim.log.levels.INFO)
            actions.conflict_choose "theirs"()
          end,
          { desc = "Choose THEIRS version (merge)" },
        },
        {
          "n",
          "<leader>gmB",
          function() actions.conflict_choose "base" end,
          { desc = "Choose BASE version (merge)" },
        },
      },
    }
  end,
}
