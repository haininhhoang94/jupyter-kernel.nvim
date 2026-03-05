local source = {}

function source.new(opts, config)
  local self = setmetatable({}, { __index = source })
  self.opts = opts or {}
  self.config = config
  return self
end

function source:get_completions(_, callback)
  local ok_kernel, kernel = pcall(require, "jupyter_kernel")
  if not ok_kernel or not kernel.ensure_attached({ prompt = false, silent = true }) then
    callback({
      items = {},
      is_incomplete_backward = false,
      is_incomplete_forward = false,
    })
    return function() end
  end

  local items = vim.fn.JupyterComplete(vim.g.__jupyter_timeout)
  if type(items) ~= "table" then
    items = {}
  end

  callback({
    items = items,
    is_incomplete_backward = false,
    is_incomplete_forward = false,
  })

  return function() end
end

return source
