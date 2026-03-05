# Pyrepl Auto-Attach + Blink Completion Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `jupyter-kernel.nvim` pair smoothly with `pyrepl.nvim` by auto-attaching to the latest running kernel and supporting `blink.cmp` completion.

**Architecture:** Add a small Lua auto-attach layer in `jupyter_kernel/init.lua` that can attach to the newest runtime kernel non-interactively and wire it into inspect/execute/completion paths. Keep existing `nvim-cmp` source, and add a native Blink source module that calls the same `JupyterComplete` backend. Register command/source conditionally so users can run without `nvim-cmp`.

**Tech Stack:** Neovim Lua API, pynvim remote plugin (`jupyter_client`), `nvim-cmp`, `blink.cmp`.

---

### Task 1: Add Config Surface for Auto-Attach and Completion Backends

**Files:**
- Modify: `lua/jupyter_kernel/init.lua`
- Modify: `README.md`

**Step 1: Add new default config fields**

Add config keys:
- `auto_attach = { enabled = true, silent = true }`
- `completion = { backend = "cmp" }` where backend values are `"cmp"`, `"blink"`, `"both"`, `"none"`.

**Step 2: Keep backward compatibility in setup merge**

Ensure `setup(opts)` deep-merges old config and still sets `vim.g.__jupyter_timeout`.

**Step 3: Verify no syntax errors**

Run: `nvim --headless -u NONE "+lua dofile('lua/jupyter_kernel/init.lua')" +qa`
Expected: exits 0.

### Task 2: Implement Non-Interactive Attach-To-Latest Flow

**Files:**
- Modify: `lua/jupyter_kernel/init.lua`

**Step 1: Add kernel listing helper and latest-picker helper**

Add helper to call `vim.fn.JupyterKernels()` and return latest kernel file (index 1).

**Step 2: Add `attach_latest` function**

Implement `M.attach_latest()` that:
- fetches latest kernel
- calls internal attach function
- returns boolean success.

**Step 3: Add `ensure_attached` function**

Implement `M.ensure_attached()` that:
- returns true immediately if already attached
- if auto-attach enabled, tries `attach_latest`
- otherwise returns false.

**Step 4: Switch inspect/execute to use ensure_attached**

Replace current prompt-only flow in `inspect()` and `execute()` so commands auto-attach when possible and only show selection prompt on fallback.

**Step 5: Verify behavior path**

Run: `nvim --headless -u NONE "+lua local m=require('jupyter_kernel'); m.setup({}); print(type(m.ensure_attached)=='function')" +qa`
Expected: prints `true` and exits 0.

### Task 3: Add Native Blink Source

**Files:**
- Create: `lua/jupyter_kernel/blink.lua`
- Modify: `plugin/jupyter_kernel.lua`
- Modify: `README.md`

**Step 1: Implement blink source module**

Create `lua/jupyter_kernel/blink.lua` with `.new(opts, config)` and `:get_completions(ctx, callback)`:
- call `require("jupyter_kernel").ensure_attached()`
- call `vim.fn.JupyterComplete(vim.g.__jupyter_timeout)`
- callback with `{ items = items, is_incomplete_backward = false, is_incomplete_forward = false }`.

**Step 2: Conditionally register cmp source**

In `plugin/jupyter_kernel.lua`, only register cmp source when backend allows cmp and `require("cmp")` succeeds.

**Step 3: Add blink global source registration helper**

Expose source via global (`_G.jupyter_kernel_blink_source = require("jupyter_kernel.blink")`) for simple `blink.cmp` config consumption.

**Step 4: Verify source file loads**

Run: `nvim --headless -u NONE "+lua dofile('lua/jupyter_kernel/blink.lua')" +qa`
Expected: exits 0.

### Task 4: Add Commands for Explicit Latest Attach and Status

**Files:**
- Modify: `plugin/jupyter_kernel.lua`
- Modify: `lua/jupyter_kernel/init.lua`
- Modify: `README.md`

**Step 1: Add `:JupyterAttachLatest` command**

Create user command mapping to `require("jupyter_kernel").attach_latest`.

**Step 2: Add clear notifications**

When latest attach fails (no kernels), show actionable message.

**Step 3: Verify command registration**

Run: `nvim --headless -u NONE "+lua dofile('plugin/jupyter_kernel.lua'); print(vim.fn.exists(':JupyterAttachLatest'))" +qa`
Expected: prints `2`.

### Task 5: Update Docs + End-to-End Verification

**Files:**
- Modify: `README.md`

**Step 1: Document pyrepl pairing workflow**

Add section: open pyrepl kernel -> auto attach in jupyter-kernel commands/completion.

**Step 2: Document blink setup snippet**

Provide `blink.cmp` provider snippet using module `jupyter_kernel.blink`.

**Step 3: Document backend config options**

List `completion.backend` values and examples (`cmp`, `blink`, `both`, `none`).

**Step 4: Run final checks**

Run:
- `python3 -m compileall rplugin/python3/jupyter_kernel`
- `nvim --headless -u NONE "+lua dofile('lua/jupyter_kernel/init.lua'); dofile('lua/jupyter_kernel/blink.lua')" +qa`

Expected: all commands exit 0.
