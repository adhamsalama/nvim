-- Kulala lives in its own tab named "HTTP": any `.http`/`.rest` file (and the scratchpad) opened
-- in another tab is moved there. The response split opens next to the request buffer
-- (kulala/ui/init.lua `open_kulala_window`), so it lands in the HTTP tab too.
--
-- Kulala's keymaps only exist in that tab. Its filetype keymaps are already buffer-local on http
-- buffers (which only live in the HTTP tab); its global ones (`<leader>rb`, `<leader>ro`, ...) are
-- removed after setup and set/cleared as the HTTP tab gains/loses focus.

local TAB_NAME = "HTTP"

local function find_http_tab()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if vim.t[tab].name == TAB_NAME then return tab end
  end
end

-- toggles kulala's global keymaps to match the current tab; a no-op until kulala has loaded
local active = false
local function sync_keymaps()
  local ok, config = pcall(require, "kulala.config")
  local maps = ok and config.options and config.options.global_keymaps
  if type(maps) ~= "table" then return end
  local want = vim.t.name == TAB_NAME
  if want == active then return end
  active = want
  for _, map in ipairs(maps) do
    local mode = map.mode or "n"
    if want then
      vim.keymap.set(mode, map[1], map[2], { desc = map.desc, silent = true, nowait = true })
    else
      pcall(vim.keymap.del, mode, map[1])
    end
  end
end

local function move_to_http_tab(buf)
  local win = vim.api.nvim_get_current_win()

  -- drop the buffer from this tab's AstroNvim buffer list and give its window something else
  vim.t.bufs = vim.tbl_filter(function(b) return b ~= buf end, vim.t.bufs or {})
  local alt = vim.fn.bufnr "#"
  if #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.api.nvim_win_close(win, false)
  elseif alt > 0 and alt ~= buf and vim.bo[alt].buflisted then
    vim.api.nvim_win_set_buf(win, alt)
  elseif #vim.t.bufs > 0 then
    vim.api.nvim_win_set_buf(win, vim.t.bufs[#vim.t.bufs])
  else
    vim.cmd.enew()
  end

  local tab = find_http_tab()
  if tab then
    vim.api.nvim_set_current_tabpage(tab)
    vim.api.nvim_win_set_buf(0, buf)
  else
    vim.cmd("tab sbuffer " .. buf)
    -- named synchronously so the TabNew handler in tab-names.lua moves it right
    vim.t.name = TAB_NAME
    vim.cmd.redrawtabline()
  end
  sync_keymaps() -- TabEnter fired before the new tab was named
end

---@type LazySpec
return {
  {
    "mistweaverco/kulala.nvim",
    keys = {
      {
        "<leader>th",
        function()
          local tab = find_http_tab()
          if tab == vim.api.nvim_get_current_tabpage() then
            vim.cmd "tabnext #" -- already there: back to the previous tab
          elseif tab then
            vim.api.nvim_set_current_tabpage(tab)
          else
            require("kulala").scratchpad() -- the FileType autocmd below moves it into a new HTTP tab
          end
        end,
        desc = "Toggle HTTP (kulala) tab",
      },
    },
    ft = { "http", "rest" },
    opts = {
      global_keymaps = true,
      global_keymaps_prefix = "<leader>r",
      kulala_keymaps_prefix = "",
    },
    config = function(_, opts)
      require("kulala").setup(opts)
      -- setup just mapped the globals everywhere; drop them unless we're in the HTTP tab
      active = true
      sync_keymaps()
    end,
  },
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      opts.autocmds = opts.autocmds or {}
      opts.autocmds.kulala_http_tab = {
        {
          event = "FileType",
          pattern = { "http", "rest" },
          desc = "Move HTTP files to the HTTP tab",
          callback = function(args)
            -- skip session restore; it puts buffers back in their saved tabs itself
            if vim.v.vim_did_enter == 0 then return end
            -- scheduled: the scratchpad sets ft before filling buffer 0, so let that finish first
            vim.schedule(function()
              local buf = args.buf
              if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then return end
              if vim.api.nvim_get_current_buf() ~= buf then return end
              -- kulala's own previews (request manager etc.) are http floats; leave them alone
              if vim.api.nvim_win_get_config(0).relative ~= "" then return end
              if vim.t.name == TAB_NAME then return end
              move_to_http_tab(buf)
            end)
          end,
        },
        {
          -- BufEnter too: session restore names tabs after entering them
          event = { "TabEnter", "BufEnter" },
          desc = "Kulala keymaps only in the HTTP tab",
          callback = sync_keymaps,
        },
      }
    end,
  },
}
