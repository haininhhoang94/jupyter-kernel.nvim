local M = {}
M._cmp_registered = false

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

function M.inspect()
  if not M.ensure_attached({ silent = true }) then
    return
  end

  local inspect = vim.fn.JupyterInspect(M.opts.timeout)
  local out = ""

  if inspect.status ~= "ok" then
    out = inspect.status
  elseif inspect.found ~= true then
    out = "_No information from kernel_"
  else
    local sections = vim.split(inspect.data["text/plain"], "\x1b%[0;31m")
    for _, section in ipairs(sections) do
      section = section
        -- Strip ANSI Escape code: https://stackoverflow.com/a/55324681
        -- \x1b is the escape character
        -- %[%d+; is the ANSI escape code for a digit color
        :gsub("\x1b%[%d+;%d+;%d+;%d+;%d+m", "")
        :gsub("\x1b%[%d+;%d+;%d+;%d+m", "")
        :gsub("\x1b%[%d+;%d+;%d+m", "")
        :gsub("\x1b%[%d+;%d+m", "")
        :gsub("\x1b%[%d+m", "")
        :gsub("\x1b%[H", "\t")
        -- Groups: name, 0 or more new line, content till end
        -- TODO: Fix for non-python kernel
        :gsub("^(Call signature):(%s*)(.-)\n$", "```python\n%3 # %1\n```")
        :gsub("^(Init signature):(%s*)(.-)\n$", "```python\n%3 # %1\n```")
        :gsub("^(Signature):(%s*)(.-)\n$",      "```python\n%3 # %1\n```")
        :gsub("^(String form):(%s*)(.-)\n$",    "```python\n%3 # %1\n```")
        :gsub("^(Docstring):(%s*)(.-)$",        "\n---\n```rst\n%3\n```")
        :gsub("^(Class docstring):(%s*)(.-)$",  "\n---\n```rst\n%3\n```")
        :gsub("^(File):(%s*)(.-)\n$",           "*%1*: `%3`\n")
        :gsub("^(Type):(%s*)(.-)\n$",           "*%1*: %3\n")
        :gsub("^(Length):(%s*)(.-)\n$",         "*%1*: %3\n")
        :gsub("^(Subclasses):(%s*)(.-)\n$",     "*%1*: %3\n")
      if section:match("%S") ~= nil and section:match("%S") ~= "" then
        -- Only add non-empty section
        out = out .. section
      end
    end
  end

  local markdown_lines = vim.lsp.util.convert_input_to_markdown_lines(out)
  markdown_lines = vim.lsp.util.trim_empty_lines(markdown_lines)
  vim.lsp.util.open_floating_preview(markdown_lines, "markdown", M.opts.inspect.window)
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
  inspect = {
    -- opts for vim.lsp.util.open_floating_preview
    window = {
      max_width = 84,
      focus_id = "jupyter",
    },
  },
  -- time to wait for kernel's response in seconds
  timeout = 0.5,
  auto_attach = {
    enabled = true,
    silent = true,
  },
  completion = {
    backend = "cmp",
    -- Disable IPython's jedi completer: much faster (no static type inference)
    -- and, against a live kernel, dir()-based introspection of real objects is
    -- typically what you want. Set true to keep jedi.
    use_jedi = false,
  },
}

M.opts = vim.deepcopy(default_config)

local function setup_completion_backends()
  local backend = M.opts.completion.backend

  if backend == "cmp" or backend == "both" then
    local ok_cmp, cmp = pcall(require, "cmp")
    if ok_cmp and not M._cmp_registered then
      cmp.register_source("jupyter", require("jupyter_kernel.cmp").new())
      M._cmp_registered = true
    end
  end

  if backend == "blink" or backend == "both" then
    _G.jupyter_kernel_blink_source = require("jupyter_kernel.blink")
  end
end

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", default_config, opts or {})
  vim.g.__jupyter_timeout = M.opts.timeout
  vim.g.__jupyter_completion_backend = M.opts.completion.backend
  setup_completion_backends()
end

return M
