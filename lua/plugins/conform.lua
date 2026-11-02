-- JS/TS formatting via conform + prettierd instead of none-ls prettier. none-ls computes its text
-- edits in pure Lua (~2s on a 19k-line file) and spawns a fresh prettier per save, so a synchronous
-- format-on-save froze nvim for seconds. conform diffs with `vim.diff` (C) and prettierd keeps prettier
-- warm (it uses the project's own node_modules prettier when present). Other filetypes are untouched.
local js_fts = { "javascript", "javascriptreact", "typescript", "typescriptreact" }

local function is_large(bufnr) return vim.api.nvim_buf_line_count(bufnr) > 3000 end

local function should_format(bufnr)
  if not vim.tbl_contains(js_fts, vim.bo[bufnr].filetype) then return false end
  -- respect AstroNvim's <Leader>uf / <Leader>uF autoformat toggles
  return vim.F.if_nil(vim.b[bufnr].autoformat, vim.g.autoformat, true)
end

local function format()
  if vim.tbl_contains(js_fts, vim.bo.filetype) then
    require("conform").format { async = true }
  else
    vim.lsp.buf.format(require("astrolsp").format_opts)
  end
end

---@type LazySpec
return {
  {
    -- astrolsp maps <Leader>lf on attach for any client with formatting (none-ls attaches to JS
    -- buffers too), which would shadow the FileType mapping; route it through `format` instead
    "AstroNvim/astrolsp",
    opts = {
      mappings = { n = { ["<Leader>lf"] = { format, desc = "Format buffer", cond = "textDocument/formatting" } } },
    },
  },
  {
    "stevearc/conform.nvim",
    ft = js_fts,
    cmd = "ConformInfo",
    init = function()
      -- for JS/TS buffers no LSP client may offer formatting, so astrolsp's mapping above won't exist
      vim.api.nvim_create_autocmd("FileType", {
        pattern = js_fts,
        desc = "Format JS/TS with conform",
        callback = function(args)
          vim.keymap.set("n", "<Leader>lf", format, { buffer = args.buf, desc = "Format buffer" })
        end,
      })
    end,
    opts = function()
      local formatters_by_ft = {}
      for _, ft in ipairs(js_fts) do
        formatters_by_ft[ft] = { "prettierd", "prettier", stop_after_first = true }
      end
      return {
        formatters_by_ft = formatters_by_ft,
        -- Small files format synchronously before the write. Large ones (prettier alone takes
        -- 0.5-3s on a 19k-line file) format asynchronously after it, so nvim never blocks; conform
        -- re-writes the buffer once the result lands.
        format_on_save = function(bufnr)
          if should_format(bufnr) and not is_large(bufnr) then return { timeout_ms = 3000, lsp_format = "never" } end
        end,
        format_after_save = function(bufnr)
          if should_format(bufnr) and is_large(bufnr) then return { lsp_format = "never" } end
        end,
      }
    end,
  },
  {
    -- keep none-ls prettier for the other filetypes (json, css, markdown, ...)
    "jay-babu/mason-null-ls.nvim",
    optional = true,
    opts = function(_, opts)
      opts.handlers = opts.handlers or {}
      opts.handlers.prettier = function()
        local null_ls = require "null-ls"
        null_ls.register(null_ls.builtins.formatting.prettier.with { disabled_filetypes = js_fts })
      end
      -- mason-null-ls auto-registers every installed formatter; prettierd is only for conform,
      -- registering it too would format json/css/... twice on save
      opts.handlers.prettierd = function() end
    end,
  },
}
