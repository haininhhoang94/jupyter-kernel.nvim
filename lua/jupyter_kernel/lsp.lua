---In-process ("virtual") LSP backed by the attached Jupyter kernel.
---
---Exposes ``textDocument/completion`` and ``textDocument/hover`` so any
---LSP-aware client (Neovim built-in, nvim-cmp, blink.cmp, …) gets kernel
---completion and inspect output without a per-client adapter. The server is a
---Lua function passed as ``cmd`` to ``vim.lsp.start`` — no process is spawned.
---Requests round-trip through the async rplugin (JupyterCompleteAsync /
---JupyterInspectAsync), so the editor stays responsive while the kernel is busy.

local async = require("jupyter_kernel.async")
local cell_mod = require("jupyter_kernel.cell")

local CompletionItemKind = vim.lsp.protocol.CompletionItemKind

local M = {}

local CLIENT_NAME = "jupyter"

---Heuristic kernel-match → CompletionItemKind. Trailing ``(`` → callable,
---ALL_CAPS → constant, otherwise variable.
---@param label string
---@return integer
local function kind_for(label)
  if label:sub(-1) == "(" then
    return CompletionItemKind.Function
  end
  if label:match("^[%u_][%u%d_]*$") then
    return CompletionItemKind.Constant
  end
  return CompletionItemKind.Variable
end

---Strip ANSI CSI escapes and ``X\bX`` overprint sequences some kernels embed
---in inspect_reply text.
---@param s string
---@return string
local function strip_terminal_codes(s)
  s = s:gsub("\27%[[%d;]*[A-Za-z]", "")
  s = s:gsub(".\008", "")
  return s
end

---@param data table<string, string>
---@return string body, string kind  kind is "markdown" or "plaintext"
local function pick_representation(data)
  local md = data["text/markdown"]
  if type(md) == "string" and md ~= "" then
    return md, "markdown"
  end
  local plain = data["text/plain"]
  if type(plain) == "string" and plain ~= "" then
    return plain, "plaintext"
  end
  return "", "plaintext"
end

---True when a kernel is attached (delegates to jupyter_kernel.ensure_attached).
---@return boolean
local function attached()
  local ok, result = pcall(function()
    local kernel = require("jupyter_kernel")
    if type(kernel) ~= "table" then
      return false
    end
    if type(kernel.ensure_attached) == "function" then
      return kernel.ensure_attached({ prompt = false, silent = true }) and true or false
    end
    return true
  end)
  return ok and result == true
end

---@param code string
---@param cursor_pos integer
---@param cb fun(err: any, result: any)
local function complete_async(code, cursor_pos, cb)
  local req_id = async.register(cb)
  vim.fn.JupyterCompleteAsync(req_id, code, cursor_pos)
end

---@param code string
---@param cursor_pos integer
---@param cb fun(err: any, result: any)
local function inspect_async(code, cursor_pos, cb)
  local req_id = async.register(cb)
  vim.fn.JupyterInspectAsync(req_id, code, cursor_pos)
end

---@param params any  textDocument/completion params
---@param callback fun(err: any, result: any)
function M._handle_completion(params, callback)
  if not attached() then
    return callback(nil, nil)
  end
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local cell = cell_mod.get_cell_at(bufnr, params.position.line)
  if cell == nil then
    return callback(nil, nil)
  end

  local code = table.concat(cell.source, "\n")
  -- Jupyter cursor_pos is in code points, not bytes.
  local cursor_pos = cell_mod.byte_to_char(code, cell_mod.position_to_offset(cell, params.position))

  local ok = pcall(complete_async, code, cursor_pos, function(err, result)
    if err ~= nil or result == nil then
      return callback(nil, nil)
    end
    -- cursor_start/end come back in code points → convert to byte offsets.
    local start_pos = cell_mod.offset_to_position(cell, cell_mod.char_to_byte(code, result.cursor_start))
    local end_pos = cell_mod.offset_to_position(cell, cell_mod.char_to_byte(code, result.cursor_end))
    local items = {}
    for i, match in ipairs(result.matches or {}) do
      items[i] = {
        label = match,
        kind = kind_for(match),
        textEdit = {
          range = { start = start_pos, ["end"] = end_pos },
          newText = match,
        },
      }
    end
    callback(nil, { items = items, isIncomplete = false })
  end)
  if not ok then
    callback(nil, nil)
  end
end

---@param params any  textDocument/hover params
---@param callback fun(err: any, result: any)
function M._handle_hover(params, callback)
  if not attached() then
    return callback(nil, nil)
  end
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local cell = cell_mod.get_cell_at(bufnr, params.position.line)
  if cell == nil then
    return callback(nil, nil)
  end

  local code = table.concat(cell.source, "\n")
  -- Jupyter cursor_pos is in code points, not bytes.
  local cursor_pos = cell_mod.byte_to_char(code, cell_mod.position_to_offset(cell, params.position))

  local ok = pcall(inspect_async, code, cursor_pos, function(err, result)
    if err ~= nil or result == nil or not result.found then
      return callback(nil, nil)
    end
    local body, kind = pick_representation(result.data or {})
    if body == "" then
      return callback(nil, nil)
    end
    callback(nil, {
      contents = {
        kind = (kind == "markdown") and "markdown" or "plaintext",
        value = strip_terminal_codes(body),
      },
    })
  end)
  if not ok then
    callback(nil, nil)
  end
end

---@type table<string, fun(params: any, callback: fun(err: any, result: any))>
local METHODS = {
  initialize = function(_, callback)
    callback(nil, {
      capabilities = {
        positionEncoding = "utf-8",
        textDocumentSync = { openClose = true, change = 0 },
        completionProvider = {
          triggerCharacters = { ".", "[", "\"", "'" },
          resolveProvider = false,
        },
        hoverProvider = true,
      },
      serverInfo = { name = "jupyter-kernel", version = "0.1" },
    })
  end,
  shutdown = function(_, callback)
    callback(nil, nil)
  end,
  ["textDocument/completion"] = function(p, cb)
    M._handle_completion(p, cb)
  end,
  ["textDocument/hover"] = function(p, cb)
    M._handle_hover(p, cb)
  end,
}

---Construct the in-process server (lsp.rpc.PublicClient contract).
---@param dispatchers table
---@return table
function M._make_server(dispatchers)
  local closing = false
  local request_id = 0
  return {
    request = function(method, params, callback)
      request_id = request_id + 1
      local handler = METHODS[method]
      if handler ~= nil then
        handler(params, callback)
      else
        callback({ code = -32601, message = "Method not found: " .. tostring(method) }, nil)
      end
      return true, request_id
    end,
    notify = function(method)
      if method == "exit" then
        closing = true
        if dispatchers and dispatchers.on_exit then
          vim.schedule(function()
            dispatchers.on_exit(0, 0)
          end)
        end
      end
      return true
    end,
    is_closing = function()
      return closing
    end,
    terminate = function()
      closing = true
    end,
  }
end

---Attach the virtual LSP to ``bufnr``. Idempotent (vim.lsp.start dedups by
---name + root_dir → buffers share one server).
---@param bufnr integer
---@return integer? client_id
function M.attach(bufnr)
  return vim.lsp.start({
    name = CLIENT_NAME,
    cmd = M._make_server,
    root_dir = vim.fn.getcwd(),
  }, { bufnr = bufnr })
end

---Detach from ``bufnr``; stop the client when no buffers remain.
---@param bufnr integer
function M.detach(bufnr)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = CLIENT_NAME })) do
    pcall(vim.lsp.buf_detach_client, bufnr, client.id)
    if next(client.attached_buffers or {}) == nil then
      vim.lsp.stop_client(client.id, false)
    end
  end
end

---Stop every active jupyter virtual LSP client.
function M.stop_all()
  for _, client in ipairs(vim.lsp.get_clients({ name = CLIENT_NAME })) do
    vim.lsp.stop_client(client.id, false)
  end
end

return M
