local toggle_key = "<leader>ac"
return {
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  config = function(_, opts)
    require("claudecode").setup(opts)

    -- The diff tab always docks the Claude terminal as a vertical split on the side
    -- (diff.lua `display_terminal_in_new_tab`, no option for it). Move it to the bottom,
    -- matching the regular terminal's position and height.
    local diff = require "claudecode.diff"
    local orig_setup_blocking_diff = diff._setup_blocking_diff
    diff._setup_blocking_diff = function(...)
      local result = orig_setup_blocking_diff(...)
      local term_buf = require("claudecode.terminal").get_active_terminal_bufnr()
      if not opts.diff_opts.open_in_new_tab or not term_buf then return result end
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == term_buf then
          vim.api.nvim_win_call(win, function() vim.cmd "wincmd J" end)
          vim.api.nvim_win_set_height(win, math.floor(vim.o.lines * opts.terminal.snacks_win_opts.height))
          break
        end
      end
      return result
    end
  end,
  keys = {
    { "<leader>a", nil, desc = "AI/Claude Code" },
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
    { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
    { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
    { "<leader>am", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select Claude model" },
    { "<leader>ab", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current buffer" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    {
      "<leader>as",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "Add file",
      ft = { "NvimTree", "neo-tree", "oil", "minifiles" },
    },
    -- Diff management
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },
  opts = {
    -- Server Configuration
    port_range = { min = 10000, max = 65535 },
    auto_start = true,
    log_level = "info", -- "trace", "debug", "info", "warn", "error"
    terminal_cmd = nil, -- Custom terminal command (default: "claude")
    -- For local installations: "~/.claude/local/claude"
    -- For native binary: use output from 'which claude'

    -- Send/Focus Behavior
    -- When true, successful sends will focus the Claude terminal if already connected
    focus_after_send = false,

    -- Selection Tracking
    track_selection = true,
    visual_demotion_delay_ms = 50,

    -- Terminal Configuration
    terminal = {
      ---@module "snacks"
      ---@type snacks.win.Config|{}
      snacks_win_opts = {
        position = "bottom",
        height = 0.4,
        width = 1.0,
        keys = {
          claude_hide = {
            toggle_key,
            function(self) self:hide() end,
            mode = "t",
            desc = "Hide",
          },
        },
      },
    },

    -- Diff Integration
    diff_opts = {
      layout = "vertical",
      open_in_new_tab = true, -- diff gets its own tab, so it never splits next to the current buffer
      hide_terminal_in_new_tab = false, -- keep Claude visible in the diff tab to ask about the change
      keep_terminal_focus = false, -- If true, moves focus back to terminal after diff opens
    },
  },
}
