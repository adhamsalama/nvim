-- Stdio MCP server that fills the quickfix list of the Neovim hosting this Claude Code session.
-- Run with `nvim --clean -l scripts/nvim_quickfix_mcp.lua`.
--
-- Claude Code only exposes a fixed set of claudecode.nvim's IDE tools to the model, so custom tools
-- need their own server. It reaches Neovim through $NVIM, which Claude inherits from the Neovim
-- terminal it runs in, and calls ClaudeSetQuickfix() defined in lua/plugins/claude.lua.

local tool = {
  name = "setQuickfixList",
  description = "Replace the user's Neovim quickfix list with code locations and open it. Use when asked "
    .. "to put search results, references, usages, TODOs or other locations in the quickfix list.",
  inputSchema = {
    type = "object",
    properties = {
      title = { type = "string", description = "Short title for the list" },
      entries = {
        type = "array",
        items = {
          type = "object",
          properties = {
            filePath = { type = "string", description = "Absolute path, or relative to the cwd" },
            line = { type = "integer", description = "1-based line number" },
            column = { type = "integer", description = "1-based column (optional)" },
            text = { type = "string", description = "Description shown in the list" },
          },
          required = { "filePath", "line" },
          additionalProperties = false,
        },
      },
      open = { type = "boolean", description = "Open the quickfix window (default true)" },
    },
    required = { "entries" },
    additionalProperties = false,
  },
}

local function set_quickfix(args)
  local server = os.getenv "NVIM"
  if not server then error("$NVIM is not set: this Claude Code session isn't running inside a Neovim terminal", 0) end
  -- Relative paths are relative to Claude's cwd, which is this process's cwd, not necessarily Neovim's.
  for _, e in ipairs(args.entries or {}) do
    e.filePath = vim.fn.fnamemodify(e.filePath, ":p")
  end
  local chan = vim.fn.sockconnect("pipe", server, { rpc = true })
  if chan == 0 then error("Could not connect to Neovim at " .. server, 0) end
  local ok, count = pcall(vim.rpcrequest, chan, "nvim_exec_lua", "return ClaudeSetQuickfix(...)", { args })
  vim.fn.chanclose(chan)
  if not ok then error(count, 0) end
  return ("Set quickfix list with %d entries"):format(count)
end

local methods = {
  initialize = function(params)
    return {
      protocolVersion = params.protocolVersion or "2024-11-05",
      capabilities = { tools = vim.empty_dict() },
      serverInfo = { name = "neovim", version = "1.0.0" },
    }
  end,
  ping = function() return vim.empty_dict() end,
  ["tools/list"] = function() return { tools = { tool } } end,
  ["tools/call"] = function(params)
    if params.name ~= tool.name then error({ code = -32602, message = "Unknown tool: " .. params.name }, 0) end
    -- Tool failures are reported to the model as a result, not a protocol error.
    local ok, text = pcall(set_quickfix, params.arguments or {})
    return { content = { { type = "text", text = tostring(text) } }, isError = not ok }
  end,
}

for line in io.stdin:lines() do
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true } })
  if ok and type(msg) == "table" and msg.id ~= nil then -- messages without an id are notifications
    local reply = { jsonrpc = "2.0", id = msg.id }
    local method = methods[msg.method]
    if not method then
      reply.error = { code = -32601, message = "Method not found: " .. tostring(msg.method) }
    else
      local call_ok, result = pcall(method, msg.params or {})
      if call_ok then
        reply.result = result
      else
        reply.error = type(result) == "table" and result or { code = -32603, message = tostring(result) }
      end
    end
    io.stdout:write(vim.json.encode(reply), "\n")
    io.stdout:flush()
  end
end
