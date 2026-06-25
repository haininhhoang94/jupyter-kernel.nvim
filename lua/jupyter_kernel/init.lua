local M = {}

local function _attach(kernel, opts)
  opts = opts or {}
  local use_jedi = (M.opts.completion and M.opts.completion.use_jedi) and 1 or 0
  vim.fn.JupyterAttach(kernel, use_jedi)
  vim.b.jupyter_attached = true

  if not opts.silent then
    vim.notify("Attach to " .. kernel)
  end
end

local function list_kernels()
  vim.fn.JupyterKernels()
  local kernels = vim.fn.JupyterKernels()
  if type(kernels) ~= "table" then
    return {}
  end
  return kernels
end

local function latest_kernel()
  local kernels = list_kernels()
  return kernels[1]
end

function M.attach(opts)
  opts = opts or {}
  local kernel = opts.args or "" -- User supplied full path
  if kernel ~= "" then -- User didn't supply full path
    _attach(kernel)
  else
    local kernels = list_kernels()
    if #kernels == 0 then
      vim.notify("No running jupyter kernels found", vim.log.levels.WARN)
      return false
    end

    kernel = vim.ui.select(kernels, { prompt = "Select a kernel" }, function(kernel)
      if kernel ~= nil then
        _attach(kernel)
      end
    end)
  end

  return vim.b.jupyter_attached == true
end

function M.attach_latest(opts)
  opts = opts or {}
  local kernel = latest_kernel()

  if not kernel then
    if not opts.silent then
      vim.notify("No running jupyter kernels found", vim.log.levels.WARN)
    end
    return false
  end

  _attach(kernel, { silent = opts.silent })
  return true
end

function M.ensure_attached(opts)
  opts = opts or {}

  if vim.b.jupyter_attached == true then
    return true
  end

  if M.opts.auto_attach.enabled then
    return M.attach_latest({ silent = opts.silent ~= false and M.opts.auto_attach.silent })
  end

  if opts.prompt ~= false then
    vim.notify("No jupyter kernel attached. Select kernel:")
    M.attach({ args = "" })
  end

  return vim.b.jupyter_attached == true
end

function M.execute(opts)
  if not M.ensure_attached({ silent = true }) then
    return
  end
  ---@diagnostic disable-next-line: param-type-mismatch
  local codes = vim.fn.getline(opts.line1) -- default to current line
  if opts.range == 2 then
    codes = vim.fn.getline(opts.line1, opts.line2)
    codes = table.concat(codes, "\n")
  elseif opts.args ~= "" then
    codes = opts.args
  end
  local status = vim.fn.JupyterExecute(codes)
  if status ~= "ok" then
    vim.notify(status)
  end
end


local default_config = {
  -- time to wait for kernel's response in seconds (legacy; kept for callers)
  timeout = 0.5,
  auto_attach = {
    enabled = true,
    silent = true,
  },
  completion = {
    -- Disable IPython's jedi completer: much faster (no static type inference)
    -- and, against a live kernel, dir()-based introspection of real objects is
    -- typically what you want. Set true to keep jedi.
    use_jedi = false,
  },
}

M.opts = vim.deepcopy(default_config)

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", default_config, opts or {})
end

return M
