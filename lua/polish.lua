-- if true then return end -- WARN: REMOVE THIS LINE TO ACTIVATE THIS FILE

-- This will run last in the setup process and is a good place to configure
-- things like custom filetypes. This is just pure lua so anything that doesn't
-- fit in the normal config locations above can go here

-- Set up custom filetypes
-- vim.filetype.add {
--   extension = {
--     foo = "fooscript",
--   },
--   filename = {
--     ["Foofile"] = "fooscript",
--   },
--   pattern = {
--     ["~/%.config/foo/.*"] = "fooscript",
--   },
-- }

-- vim.keymap.set("n", "<leader>gd", "<cmd>DiffviewOpen<cr>", { desc = "View Git diff" })

vim.opt.guicursor = "n-v-c-sm:block,ci-ve:ver25,r-cr-o:hor20,i:block-blinkwait700-blinkoff400-blinkon250-Cursor/lCursor"

-- Custom quickfix text function to hide column numbers
_G.qftextfunc_no_col = function(info)
  local items
  local ret = {}
  if info.quickfix == 1 then
    items = vim.fn.getqflist({ id = info.id, items = 0 }).items
  else
    items = vim.fn.getloclist(info.winid, { id = info.id, items = 0 }).items
  end

  for i = info.start_idx, info.end_idx do
    local e = items[i]
    local str
    if e.valid == 1 then
      local fname = ""
      if e.bufnr > 0 then
        fname = vim.fn.bufname(e.bufnr)
        if fname == "" then
          fname = "[No Name]"
        else
          -- Make path relative to current working directory
          local cwd = vim.fn.getcwd()
          if fname:sub(1, #cwd) == cwd then
            fname = fname:sub(#cwd + 2) -- +2 to skip the trailing slash
          else
            -- Fallback to home directory substitution if not in cwd
            fname = fname:gsub("^" .. vim.env.HOME, "~")
          end
        end
      end

      local lnum = e.lnum > 0 and e.lnum or 0
      local text = e.text or ""

      -- Format: filename|line| text (without column)
      if fname ~= "" then
        str = string.format("%s|%d| %s", fname, lnum, text)
      else
        str = string.format("|%d| %s", lnum, text)
      end
    else
      str = e.text
    end
    table.insert(ret, str)
  end
  return ret
end

-- LSP reference counts shown as virtual lines above functions
do
  local ns = vim.api.nvim_create_namespace "lsp_ref_count"
  local filetypes = {
    typescript = true,
    javascript = true,
    typescriptreact = true,
    javascriptreact = true,
    go = true,
  }
  local lang_map = { typescriptreact = "tsx", javascriptreact = "javascript" }

  local query_strs = {
    javascript = [[
      (function_declaration name: (identifier) @name)
      (method_definition name: (property_identifier) @name)
      (variable_declarator name: (identifier) @name value: [(arrow_function) (function_expression)])
    ]],
    go = [[
      (function_declaration name: (identifier) @name)
      (method_declaration name: (field_identifier) @name)
      (type_declaration (type_spec name: (type_identifier) @name type: (struct_type)))
    ]],
  }
  query_strs.typescript = query_strs.javascript
    .. [[
    (public_field_definition name: (property_identifier) @name value: [(arrow_function) (function_expression)])
  ]]
  query_strs.tsx = query_strs.typescript

  local queries = {}
  local function get_query(lang)
    if queries[lang] == nil then
      local str = query_strs[lang] or query_strs.javascript
      local ok, q = pcall(vim.treesitter.query.parse, lang, str)
      queries[lang] = ok and q or false
    end
    return queries[lang]
  end

  local enabled = true
  local tokens = {}

  local function refresh(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not enabled then return end
    if not filetypes[vim.bo[bufnr].filetype] then return end
    if #vim.lsp.get_clients { bufnr = bufnr } == 0 then return end

    local ft = vim.bo[bufnr].filetype
    local lang = lang_map[ft] or ft
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
    if not ok then return end

    local tree = parser:parse()[1]
    if not tree then return end

    local query = get_query(lang)
    if not query then return end

    local token = {}
    tokens[bufnr] = token
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    for _, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
      local row, col = node:start()
      local indent = vim.fn.indent(row + 1)
      local params = {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
        position = { line = row, character = col },
        context = { includeDeclaration = false },
      }
      vim.lsp.buf_request_all(bufnr, "textDocument/references", params, function(results)
        if tokens[bufnr] ~= token or not vim.api.nvim_buf_is_valid(bufnr) then return end
        local seen = {}
        local count = 0
        for _, res in pairs(results) do
          for _, ref in ipairs(res.result or {}) do
            local key = (ref.uri or "") .. ref.range.start.line .. ":" .. ref.range.start.character
            if not seen[key] then
              seen[key] = true
              count = count + 1
            end
          end
        end
        local label = count == 1 and "1 reference" or (count .. " references")
        local padding = string.rep(" ", indent)
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
          virt_lines = { { { padding .. label, "Comment" } } },
          virt_lines_above = true,
        })
      end)
    end
  end

  local timers = {}
  local function schedule_refresh(bufnr)
    if timers[bufnr] then timers[bufnr]:stop() end
    timers[bufnr] = vim.defer_fn(function()
      timers[bufnr] = nil
      refresh(bufnr)
    end, 600)
  end

  vim.api.nvim_create_autocmd("BufEnter", {
    callback = function(args)
      if not filetypes[vim.bo[args.buf].filetype] then return end
      local marks = vim.api.nvim_buf_get_extmarks(args.buf, ns, 0, -1, { limit = 1 })
      if #marks == 0 then schedule_refresh(args.buf) end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWritePost", "InsertLeave" }, {
    callback = function(args)
      if filetypes[vim.bo[args.buf].filetype] then schedule_refresh(args.buf) end
    end,
  })

  vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(args)
      if filetypes[vim.bo[args.buf].filetype] then schedule_refresh(args.buf) end
    end,
  })

  vim.api.nvim_create_user_command("RefCountRefresh", function() refresh() end, { desc = "Refresh LSP reference counts" })

  vim.keymap.set("n", "<leader>lt", function()
    enabled = not enabled
    if enabled then
      refresh()
      vim.notify "Reference counts enabled"
    else
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      end
      vim.notify "Reference counts disabled"
    end
  end, { desc = "Toggle reference counts" })

  vim.api.nvim_create_user_command("RefCountDebug", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local ft = vim.bo[bufnr].filetype
    local lang = lang_map[ft] or ft
    local clients = vim.lsp.get_clients { bufnr = bufnr }
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
    local query = get_query(lang)
    local count = 0
    if ok and parser then
      local tree = parser:parse()[1]
      if tree and query then
        for _, _ in query:iter_captures(tree:root(), bufnr, 0, -1) do
          count = count + 1
        end
      end
    end
    vim.notify(
      string.format(
        "lsp-ref-count debug:\n  filetype: %s\n  lang: %s\n  LSP clients: %d\n  parser ok: %s\n  query ok: %s\n  functions found: %d",
        ft,
        lang,
        #clients,
        tostring(ok),
        tostring(query ~= false),
        count
      )
    )
  end, { desc = "Debug LSP reference counts" })
end

-- Add keymap to delete quickfix/location list entries with "dd"
vim.api.nvim_create_autocmd("FileType", {
  pattern = "qf",
  callback = function(event)
    vim.keymap.set("n", "dd", function()
      -- Get current line number
      local line = vim.fn.line "."

      -- Check if this is a location list or quickfix list
      local is_loclist = vim.fn.getloclist(0, { filewinid = 0 }).filewinid ~= 0

      if is_loclist then
        -- Location list
        local items = vim.fn.getloclist(0, { items = 0 }).items
        table.remove(items, line)
        vim.fn.setloclist(0, {}, "r", { items = items })
      else
        -- Quickfix list
        local items = vim.fn.getqflist({ items = 0 }).items
        table.remove(items, line)
        vim.fn.setqflist({}, "r", { items = items })
      end

      -- Restore cursor position
      local new_last_line = vim.fn.line "$"
      local target_line = math.min(line, new_last_line)
      vim.fn.cursor(target_line, 0)
    end, { buffer = event.buf, desc = "Delete quickfix/location list entry" })
  end,
})
