-- Terminal-mode toggle must not start with a printable key: with <leader>=<space>,
-- typing " ac" (e.g. "an account") in the Claude prompt would hide the window.
local toggle_key = "<C-,>"

-- The Claude terminal window, when it's visible in the current tab.
local function claude_term_win()
  local term_buf = require("claudecode.terminal").get_active_terminal_bufnr()
  if not term_buf then return end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == term_buf then return win end
  end
end

-- Opens the quickfix window without moving focus out of the Claude terminal. :copen is run from an editor window
-- because bqf places its preview relative to the window :copen came from (winnr("#")): run from the terminal,
-- the preview would cover it. The ClaudeCodeTermAtBottom autocmd then keeps the terminal below the list.
local function open_quickfix()
  local cur_win = vim.api.nvim_get_current_win()
  local from = cur_win
  for _, win in ipairs { cur_win, vim.fn.win_getid(vim.fn.winnr "#"), unpack(vim.api.nvim_tabpage_list_wins(0)) } do
    if
      vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_config(win).relative == ""
      and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
    then
      from = win
      break
    end
  end
  vim.cmd "cclose"
  vim.api.nvim_win_call(from, function() vim.cmd "botright copen" end)
  if vim.api.nvim_win_is_valid(cur_win) then vim.api.nvim_set_current_win(cur_win) end
end

-- Called over $NVIM by scripts/nvim_quickfix_mcp.lua, an MCP server registered with Claude Code. Claude Code only
-- exposes a fixed set of claudecode.nvim's IDE tools to the model, so the plugin can't provide this tool itself.
-- Takes { title?, entries = { { filePath, line, column?, text? } }, open? }.
function _G.ClaudeSetQuickfix(params)
  if type(params) ~= "table" or type(params.entries) ~= "table" then
    error("ClaudeSetQuickfix: expected { entries = {...} }, got " .. vim.inspect(params), 0)
  end
  local items = vim.tbl_map(
    function(e) return { filename = e.filePath, lnum = e.line, col = e.column or 1, text = e.text or "" } end,
    params.entries
  )
  vim.fn.setqflist({}, " ", { title = params.title or "Claude", items = items })
  if params.open ~= false then open_quickfix() end
  return #items
end

return {
  "coder/claudecode.nvim",
  dependencies = { "folke/snacks.nvim" },
  config = function(_, opts)
    require("claudecode").setup(opts)

    -- Keep the Claude terminal as the full-width bottom window: anything else opened botright (:copen, reopening
    -- the quickfix list after :cclose, ...) would otherwise land below it.
    local function move_term_to_bottom()
      local term_win = claude_term_win()
      if not term_win then return end
      local layout = vim.fn.winlayout()
      local last = layout[1] == "col" and layout[2][#layout[2]]
      if last and last[1] == "leaf" and last[2] == term_win then return end
      vim.api.nvim_win_call(term_win, function() vim.cmd "wincmd J" end)
      vim.api.nvim_win_set_height(term_win, math.floor(vim.o.lines * opts.terminal.snacks_win_opts.height))
    end
    vim.api.nvim_create_autocmd({ "WinNew", "BufWinEnter" }, {
      group = vim.api.nvim_create_augroup("ClaudeCodeTermAtBottom", { clear = true }),
      callback = function() vim.schedule(move_term_to_bottom) end,
      desc = "Keep the Claude Code terminal at the bottom",
    })

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
    { toggle_key, "<cmd>ClaudeCode<cr>", mode = { "n", "i" }, desc = "Toggle Claude" },
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
