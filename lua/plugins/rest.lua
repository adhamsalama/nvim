-- rest.nvim lives in its own tab named "HTTP": any `.http` file opened in another tab is moved
-- there. The response split opens next to the request buffer, so it lands in the HTTP tab too.
--
-- rest.nvim's keymaps are buffer-local on http buffers, which only live in the HTTP tab.
-- JSON response bodies are pretty-printed with `jq` (rest.nvim formats via the json `formatprg`).
--
-- INSTALL NOTE: Lazy builds rest.nvim's luarocks deps with its bundled hererocks (Lua 5.1). The
-- `tree-sitter-http` rock needs the `luarocks-build-treesitter-parser` build backend, and luarocks
-- <= 3.13.0 installs that backend into the plugin's `--tree` but can't load it from there on Lua
-- 5.1 (https://github.com/luarocks/luarocks/issues/1843, fixed by PR #1939, unreleased as of
-- 2026-11). The build then fails, Lazy wipes the half-installed rocks, and `:checkhealth rest-nvim`
-- reports mimetypes/xml2lua/fidget.nvim missing. Workaround: install the backend into hererocks'
-- own tree, then `:Lazy build rest.nvim`:
--   ~/.local/share/nvim/lazy-rocks/hererocks/bin/luarocks --lua-version 5.1 install luarocks-build-treesitter-parser
-- Drop this note once a luarocks release includes the fix.

local TAB_NAME = "HTTP"
local PREFIX = "<Leader>r"
local SCRATCH = vim.fs.joinpath(vim.fn.stdpath "data", "rest-scratch.http")

local function find_http_tab()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if vim.t[tab].name == TAB_NAME then return tab end
  end
end

local function move_to_http_tab(buf)
  local win = vim.api.nvim_get_current_win()

  -- drop the buffer from this tab's AstroNvim buffer list and give its window something else
  vim.t.bufs = vim.tbl_filter(function(b) return b ~= buf end, vim.t.bufs or {})
  local alt = vim.fn.bufnr "#"
  local splits = vim.tbl_filter(
    function(w) return vim.api.nvim_win_get_config(w).relative == "" end,
    vim.api.nvim_tabpage_list_wins(0)
  )
  if #splits > 1 then
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
end

local function set_buffer_maps(buf)
  local function map(lhs, rhs, desc) vim.keymap.set("n", PREFIX .. lhs, rhs, { buffer = buf, desc = desc }) end
  map("r", "<Cmd>Rest run<CR>", "Run request under cursor")
  map("l", "<Cmd>Rest last<CR>", "Re-run last request")
  map("o", "<Cmd>Rest open<CR>", "Open result pane")
  map("e", "<Cmd>Rest env select<CR>", "Select env file")
  map("E", "<Cmd>Rest env show<CR>", "Show env file")
  map("c", "<Cmd>Rest cookies<CR>", "Edit cookies")
  map("L", "<Cmd>Rest logs<CR>", "Show logs")
end

---@type LazySpec
return {
  {
    "rest-nvim/rest.nvim",
    ft = "http",
    cmd = "Rest",
    dependencies = { "nvim-treesitter/nvim-treesitter" },
    opts = {},
    config = function(_, opts) vim.g.rest_nvim = vim.tbl_deep_extend("force", vim.g.rest_nvim or {}, opts) end,
  },
  {
    "AstroNvim/astrocore",
    ---@param opts AstroCoreOpts
    opts = function(_, opts)
      opts.treesitter = opts.treesitter or {}
      opts.treesitter.ensure_installed = opts.treesitter.ensure_installed or {}
      vim.list_extend(opts.treesitter.ensure_installed, { "http" })

      -- set here rather than in lazy `keys` so it overrides AstroNvim's toggleterm <Leader>th
      opts.mappings = opts.mappings or {}
      opts.mappings.n = opts.mappings.n or {}
      opts.mappings.n["<Leader>th"] = {
        function()
          local tab = find_http_tab()
          if tab == vim.api.nvim_get_current_tabpage() then
            vim.cmd "tabnext #" -- already there: back to the previous tab
          elseif tab then
            vim.api.nvim_set_current_tabpage(tab)
          else
            vim.cmd.edit(vim.fn.fnameescape(SCRATCH)) -- the FileType autocmd below moves it into a new HTTP tab
          end
        end,
        desc = "Toggle HTTP (rest.nvim) tab",
      }

      opts.autocmds = opts.autocmds or {}
      opts.autocmds.rest_json_format = {
        {
          event = "FileType",
          pattern = "json",
          desc = "Format JSON with jq (used by rest.nvim for response bodies)",
          callback = function(args) vim.bo[args.buf].formatprg = "jq --indent 2 ." end,
        },
      }
      opts.autocmds.rest_http_tab = {
        {
          event = "FileType",
          pattern = "http",
          desc = "rest.nvim keymaps and HTTP tab for http files",
          callback = function(args)
            set_buffer_maps(args.buf)
            -- skip session restore; it puts buffers back in their saved tabs itself
            if vim.v.vim_did_enter == 0 then return end
            vim.schedule(function()
              local buf = args.buf
              if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then return end
              if vim.api.nvim_get_current_buf() ~= buf then return end
              if vim.api.nvim_win_get_config(0).relative ~= "" then return end -- leave floats alone
              if vim.t.name == TAB_NAME then return end
              move_to_http_tab(buf)
            end)
          end,
        },
      }
    end,
  },
}
