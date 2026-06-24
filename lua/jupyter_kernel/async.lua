---Pending-request registry for async kernel RPCs.
---
---The Python rplugin runs complete/inspect on a worker thread, then calls
---back via ``nvim.exec_lua("require('jupyter_kernel.async')._resolve(...)")``.
---This module owns the per-id callback table and fires them on the main loop.

local M = {}

---@type table<integer, fun(err: string?, result: any)>
local pending = {}
local next_id = 0

---Register ``callback`` against a fresh request id and return the id.
---@param callback fun(err: string?, result: any)
---@return integer req_id
function M.register(callback)
  next_id = next_id + 1
  pending[next_id] = callback
  return next_id
end

---Cancel a pending request without invoking its callback.
---@param req_id integer
function M.cancel(req_id)
  pending[req_id] = nil
end

---Called from the rplugin. Looks up the callback and dispatches it on the main
---loop. Unknown ids are ignored so a late reply never crashes Neovim. ``vim.NIL``
---(msgpack form of Python ``None``) is normalized to Lua ``nil``.
---@param req_id integer
---@param err any
---@param result any
function M._resolve(req_id, err, result)
  local callback = pending[req_id]
  if callback == nil then
    return
  end
  pending[req_id] = nil
  if err == vim.NIL then
    err = nil
  end
  if result == vim.NIL then
    result = nil
  end
  vim.schedule(function()
    callback(err, result)
  end)
end

return M
