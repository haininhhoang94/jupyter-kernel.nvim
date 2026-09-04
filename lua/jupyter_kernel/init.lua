local M = {}
local attached_kernel = nil

local function _attach(kernel, opts)
  opts = opts or {}
  local use_jedi = (M.opts.completion and M.opts.completion.use_jedi) and 1 or 0
  local ok, result = pcall(vim.fn.JupyterAttach, kernel, use_jedi)
  if not ok or result ~= "ok" then
    local message = tostring(result)
    if not opts.silent then
      vim.notify("Unable to attach Jupyter kernel: " .. message, vim.log.levels.ERROR)
    end
    return false
  end

  attached_kernel = kernel
  vim.b.jupyter_attached = true

  if not opts.silent then
    vim.notify("Attach to " .. kernel)
  end
  return true
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
  if kernel ~= "" then
    return _attach(kernel)
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

  return attached_kernel ~= nil
end

function M.attach_kernel(kernel, opts)
  if type(kernel) ~= "string" or kernel == "" then
    return false
  end
  if attached_kernel == kernel then
    vim.b.jupyter_attached = true
    return true
  end
  return _attach(kernel, opts)
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

  return M.attach_kernel(kernel, { silent = opts.silent })
end

function M.ensure_attached(opts)
  opts = opts or {}

  if attached_kernel ~= nil then
    vim.b.jupyter_attached = true
    return true
  end

  if M.opts.auto_attach.enabled then
    return M.attach_latest({ silent = opts.silent ~= false and M.opts.auto_attach.silent })
  end

  if opts.prompt ~= false then
    vim.notify("No jupyter kernel attached. Select kernel:")
    M.attach({ args = "" })
  end

  return attached_kernel ~= nil
end

function M.detach(opts)
  opts = opts or {}
  if attached_kernel == nil then
    vim.b.jupyter_attached = false
    return true
  end

  local ok, result = pcall(vim.fn.JupyterDetach)
  attached_kernel = nil
  vim.b.jupyter_attached = false
  if (not ok or result ~= "ok") and not opts.silent then
    vim.notify("Unable to detach Jupyter kernel: " .. tostring(result), vim.log.levels.WARN)
  elseif not opts.silent then
    vim.notify("Jupyter kernel detached", vim.log.levels.INFO)
  end
  return ok and result == "ok"
end

function M.current_kernel()
  return attached_kernel
end

function M.inspect(opts)
  opts = opts or {}
  local fallback = opts.fallback or function()
    vim.lsp.buf.hover()
  end
  if not M.ensure_attached({ prompt = false, silent = true }) then
    fallback()
    return false
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  require("jupyter_kernel.lsp").inspect_at(bufnr, {
    line = cursor[1] - 1,
    character = cursor[2],
  }, function(err, result)
    if err or not result or not result.contents then
      fallback()
      return
    end
    local lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
    lines = vim.lsp.util.trim_empty_lines(lines)
    if vim.tbl_isempty(lines) then
      fallback()
      return
    end
    local window = vim.tbl_deep_extend("force", { border = "rounded" }, M.opts.inspect.window or {})
    vim.lsp.util.open_floating_preview(lines, "markdown", window)
  end)
  return true
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
    pyrepl_events = true,
  },
  completion = {
    -- Disable IPython's jedi completer: much faster (no static type inference)
    -- and, against a live kernel, dir()-based introspection of real objects is
    -- typically what you want. Set true to keep jedi.
    use_jedi = false,
  },
  inspect = {
    window = {},
  },
}

M.opts = vim.deepcopy(default_config)

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", default_config, opts or {})
  local group = vim.api.nvim_create_augroup("JupyterKernelPyreplLifecycle", { clear = true })
  if M.opts.auto_attach.pyrepl_events then
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "PyreplKernelReady",
      callback = function(args)
        local connection_file = args.data and args.data.connection_file or nil
        if connection_file then
          M.attach_kernel(connection_file, { silent = M.opts.auto_attach.silent })
        end
      end,
    })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = { "PyreplKernelStopped", "PyreplKernelError" },
      callback = function()
        M.detach({ silent = true })
      end,
    })
  end
end

return M
