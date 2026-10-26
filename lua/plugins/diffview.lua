return {
  {
    "rebelot/heirline.nvim",
    opts = function(_, opts)
      -- Shown in diffview windows (diff buffers and its panels) while whitespace is ignored
      local component = {
        condition = function()
          local in_diffview = vim.wo.diff or vim.bo.filetype:match "^Diffview" ~= nil
          return in_diffview and vim.tbl_contains(vim.opt.diffopt:get(), "iwhiteall")
        end,
        provider = " 󱁐 ignore ws ",
        hl = { fg = "bg", bg = "yellow", bold = true },
      }
      table.insert(opts.statusline, 6, component)
    end,
  },
  {
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
    -- branch: feat/diffview-branch-commits
    {
      "<leader>gB",
      function()
        vim.ui.input({ prompt = "Enter branch to compare (leave empty for origin/HEAD): " }, function(branch)
          if branch == nil then return end
          local target = (branch ~= "") and ("origin/" .. branch) or "origin/HEAD"
          -- Two dots: commits reachable from HEAD but not from the target branch
          vim.cmd("DiffviewFileHistory --range=" .. target .. "..HEAD")
        end)
      end,
      desc = "Diff branch commits",
    },
    {
      "<leader>gH",
      function()
        vim.ui.input({ prompt = "Commit hash: " }, function(hash)
          if hash == nil or hash == "" then return end
          vim.fn.system { "git", "rev-parse", "--verify", "--quiet", hash .. "^2" }
          if vim.v.shell_error == 0 then
            -- Merge commit: show the commits it brought in, excluding the merge commit itself
            vim.cmd("DiffviewFileHistory --range=" .. hash .. "^1.." .. hash .. "^2")
          else
            vim.cmd("DiffviewFileHistory --range=" .. hash .. "^!")
          end
        end)
      end,
      desc = "Diff commit hash",
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
    vim.opt.diffopt:append "iwhiteall" -- on by default, toggle with <leader>gw

    -- Re-indenting (e.g. wrapping code in try/catch) marks every line as changed whatever the algorithm is,
    -- so offer a whitespace-insensitive toggle for the rendered diff
    vim.keymap.set("n", "<leader>gw", function()
      local on = vim.tbl_contains(vim.opt.diffopt:get(), "iwhiteall")
      if on then
        vim.opt.diffopt:remove "iwhiteall"
      else
        vim.opt.diffopt:append "iwhiteall"
      end
      vim.cmd.diffupdate()
      vim.cmd.redrawstatus { bang = true }
      vim.notify("Diff ignore whitespace: " .. (on and "off" or "on"), vim.log.levels.INFO)
    end, { desc = "Toggle diff ignore whitespace" })

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

    -- Diffview re-opens the current file on tab re-enter, which resets folds and window sizes.
    -- Snapshot them when leaving the view and restore once the view has been re-rendered.
    local saved = {}
    local restore_timer = vim.uv.new_timer()

    local function snapshot()
      local tab = vim.api.nvim_get_current_tabpage()
      local wins = {}
      for i, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        local buf = vim.api.nvim_win_get_buf(win)
        wins[i] = vim.api.nvim_win_call(win, function()
          local closed = {}
          if vim.wo.foldenable then
            local lnum, last = 1, vim.api.nvim_buf_line_count(buf)
            while lnum <= last do
              if vim.fn.foldclosed(lnum) == lnum then
                table.insert(closed, lnum)
                lnum = vim.fn.foldclosedend(lnum) + 1
              else
                lnum = lnum + 1
              end
            end
          end
          return { name = vim.api.nvim_buf_get_name(buf), closed = closed, view = vim.fn.winsaveview() }
        end)
      end
      saved[tab] = { layout = vim.fn.winrestcmd(), wins = wins }
    end

    local function restore()
      local tab = vim.api.nvim_get_current_tabpage()
      local state = saved[tab]
      if not state then return end
      saved[tab] = nil
      local wins = vim.api.nvim_tabpage_list_wins(tab)
      if #wins ~= #state.wins then return end
      vim.cmd(state.layout)
      for i, win in ipairs(wins) do
        local s = state.wins[i]
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_buf_get_name(buf) == s.name then
          vim.api.nvim_win_call(win, function()
            if vim.wo.foldenable then
              vim.cmd "normal! zR"
              local last = vim.api.nvim_buf_line_count(buf)
              for _, lnum in ipairs(s.closed) do
                if lnum <= last then
                  vim.api.nvim_win_set_cursor(win, { lnum, 0 })
                  pcall(vim.cmd, "normal! zc")
                end
              end
            end
            vim.fn.winrestview(s.view)
          end)
        end
      end
    end

    -- Debounced: diffview opens the files asynchronously, so wait until it settles
    local function schedule_restore(delay)
      restore_timer:stop()
      restore_timer:start(delay, 0, vim.schedule_wrap(restore))
    end

    opts.hooks = {
      view_leave = snapshot,
      view_enter = function() schedule_restore(150) end,
      diff_buf_win_enter = function()
        if saved[vim.api.nvim_get_current_tabpage()] then schedule_restore(50) end
      end,
      view_closed = function() saved[vim.api.nvim_get_current_tabpage()] = nil end,
    }

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
            local commit_hash = line:match "|[^|]*|%s*(%x+)"
            if commit_hash and #commit_hash >= 7 then
              vim.cmd("DiffviewOpen " .. commit_hash .. "^!")
            else
              vim.notify("Could not find commit hash on this line", vim.log.levels.WARN)
            end
          end,
          { desc = "Open commit in diffview" },
        },
        {
          "n",
          "gH",
          function()
            local line = vim.fn.getline "."
            local commit_hash = line:match "|[^|]*|%s*(%x+)"
            if not (commit_hash and #commit_hash >= 7) then
              vim.notify("Could not find commit hash on this line", vim.log.levels.WARN)
              return
            end
            vim.fn.system { "git", "rev-parse", "--verify", "--quiet", commit_hash .. "^2" }
            if vim.v.shell_error ~= 0 then
              vim.notify(commit_hash .. " is not a merge commit", vim.log.levels.WARN)
              return
            end
            -- Commits brought in by the merge, excluding the merge commit itself
            vim.cmd("DiffviewFileHistory --range=" .. commit_hash .. "^1.." .. commit_hash .. "^2")
          end,
          { desc = "Show commits of merge commit" },
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
},
}
