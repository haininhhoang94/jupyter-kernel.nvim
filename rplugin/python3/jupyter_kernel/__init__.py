import queue
import threading
import time
from concurrent.futures import Future
from pathlib import Path

import pynvim
from jupyter_client import BlockingKernelClient
from jupyter_core.paths import jupyter_runtime_dir

_RPC_TIMEOUT_SECONDS = 60.0
# How often the worker polls the shell channel while replies are outstanding.
_REPLY_POLL_SECONDS = 0.01


class _Worker:
  """Single daemon thread that owns the BlockingKernelClient.

  jupyter_client's ZMQ sockets are thread-affine, so every client operation
  (attach / execute / complete / inspect) is funnelled through one thread via
  a FIFO queue. Jobs only *send* requests; they never block waiting for the
  kernel. Requests that want a reply register their msg_id in ``_pending`` and
  the worker loop routes shell replies to them by ``parent_header.msg_id``
  (the shell channel is shared, so replies may arrive in any order and must
  never be consumed by the wrong waiter). A slow kernel therefore never stalls
  later jobs (e.g. a sync ``JupyterExecute`` queued behind an inspect).
  """

  def __init__(self, get_client):
    self._get_client = get_client
    self._q: "queue.Queue" = queue.Queue()
    # msg_id -> (future, transform, deadline). Touched only on the worker thread.
    self._pending: dict = {}
    self._thread = threading.Thread(
        target=self._run, name="jupyter-kernel-worker", daemon=True
    )
    self._thread.start()

  def _run(self):
    while True:
      try:
        item = self._q.get(timeout=_REPLY_POLL_SECONDS if self._pending else None)
      except queue.Empty:
        item = None
      if item is not None:
        fn, fut = item
        if fn is None:
          return
        if fut.set_running_or_notify_cancel():
          try:
            fut.set_result(fn())
          except BaseException as exc:  # noqa: BLE001 - propagate to caller
            fut.set_exception(exc)
      if self._pending:
        self._route_replies()

  def _route_replies(self):
    client = self._get_client()
    if client is None:
      self.fail_pending("No jupyter kernel attached")
      return
    try:
      while True:
        try:
          msg = client.get_shell_msg(timeout=0)
        except queue.Empty:
          break
        msg_id = (msg.get("parent_header") or {}).get("msg_id")
        entry = self._pending.pop(msg_id, None)
        if entry is None:
          continue  # reply nobody waits for (fire-and-forget execute, timed out)
        fut, transform, _ = entry
        try:
          fut.set_result(transform(msg["content"]))
        except BaseException as exc:  # noqa: BLE001
          fut.set_exception(exc)
      # Nothing here reads iopub; drop it so ZMQ buffers don't grow.
      while client.iopub_channel.msg_ready():
        client.get_iopub_msg(timeout=0)
    except Exception as exc:  # noqa: BLE001 - channel closed mid-read etc.
      self.fail_pending(f"kernel channel error: {exc}")
      return
    now = time.monotonic()
    for msg_id in [m for m, (_, _, d) in self._pending.items() if d <= now]:
      fut, _, _ = self._pending.pop(msg_id)
      fut.set_exception(TimeoutError("Timeout waiting for kernel reply"))

  def fail_pending(self, reason):
    """Fail every outstanding reply. Call on the worker thread only."""
    pending, self._pending = self._pending, {}
    for fut, _, _ in pending.values():
      fut.set_exception(RuntimeError(reason))

  def submit(self, fn) -> "Future":
    fut: "Future" = Future()
    self._q.put((fn, fut))
    return fut

  def request(self, send, transform, timeout=_RPC_TIMEOUT_SECONDS) -> "Future":
    """Run ``send`` (returns a msg_id) on the worker; the returned Future
    resolves with ``transform(reply_content)`` once the matching reply lands."""
    reply: "Future" = Future()

    def _send():
      msg_id = send()
      self._pending[msg_id] = (reply, transform, time.monotonic() + timeout)

    def _chain(sent):
      exc = sent.exception()
      if exc is not None:
        reply.set_exception(exc)

    self.submit(_send).add_done_callback(_chain)
    return reply


@pynvim.plugin
class JupyterKernel:

  def __init__(self, vim):
    self.vim: pynvim.Nvim = vim
    self.client: BlockingKernelClient | None = None
    self.kerneldir = Path(jupyter_runtime_dir())
    self._worker = _Worker(lambda: self.client)

  # --------------------------------------------------------------------
  # Worker helpers
  # --------------------------------------------------------------------

  def _run_sync(self, fn, timeout=_RPC_TIMEOUT_SECONDS):
    return self._worker.submit(fn).result(timeout=timeout)

  def _on_async_done(self, req_id, future):
    try:
      result = future.result()
    except BaseException as exc:  # noqa: BLE001
      self._dispatch_resolve(req_id, str(exc) or type(exc).__name__, None)
      return
    self._dispatch_resolve(req_id, None, result)

  def _dispatch_resolve(self, req_id, err, result):
    # Bounce onto nvim's main loop, then into Lua. Runs from the worker thread.
    self.vim.async_call(self._resolve, req_id, err, result)

  def _resolve(self, req_id, err, result):
    self.vim.exec_lua(
        "require('jupyter_kernel.async')._resolve(...)", req_id, err, result
    )

  def _async_request(self, req_id, send, transform, timeout=_RPC_TIMEOUT_SECONDS):
    self._worker.request(send, transform, timeout).add_done_callback(
        lambda f: self._on_async_done(req_id, f)
    )

  def _require_client(self) -> BlockingKernelClient:
    assert self.client is not None, "No jupyter kernel attached"
    return self.client

  # --------------------------------------------------------------------
  # Kernel discovery / lifecycle
  # --------------------------------------------------------------------

  @pynvim.function("JupyterKernels", sync=True)
  def running_kernels(self, args):
    del args
    kernels = self.kerneldir.glob('kernel-*.json')
    kernels = sorted(kernels, reverse=True, key=lambda f: f.stat().st_ctime)
    return [kern.name for kern in kernels]

  @pynvim.function("JupyterAttach", sync=True)
  def attach(self, args):
    kernel = args[0]
    use_jedi = bool(args[1]) if len(args) > 1 else True

    def _do_attach():
      self._worker.fail_pending("kernel re-attached")
      if self.client is not None:
        self.client.stop_channels()
      client = BlockingKernelClient()
      client.load_connection_file(self.kerneldir / kernel)
      client.start_channels()
      if not use_jedi:
        # Faster, live-object-aware completion. Silent: no history/output.
        try:
          client.execute("get_ipython().Completer.use_jedi = False", silent=True)
        except Exception:
          pass
      self.client = client

    self._run_sync(_do_attach)
    return "ok"

  @pynvim.function('JupyterDetach', sync=True)
  def detach(self, args):
    del args

    def _do_detach():
      self._worker.fail_pending("kernel detached")
      if self.client is not None:
        self.client.stop_channels()
        self.client = None

    self._run_sync(_do_detach)
    self.vim.command("let b:jupyter_attached = v:false")
    return "ok"

  # --------------------------------------------------------------------
  # Code execution
  # --------------------------------------------------------------------

  @pynvim.function("JupyterExecute", sync=True)
  def execute(self, args):
    """Fire-and-forget execute. ``JupyterExecute(code, {silent = bool})``;
    silent defaults to False for backwards compatibility."""
    code = args[0]
    opts = args[1] if len(args) > 1 and isinstance(args[1], dict) else {}
    silent = bool(opts.get("silent", False))

    def _do():
      self._require_client().execute(code, silent=silent)
      return "ok"

    try:
      return self._run_sync(_do)
    except Exception as e:
      return f"Exception: {str(e)}"

  @pynvim.function("JupyterExecuteAsync", sync=False)
  def execute_async(self, args):
    """``JupyterExecuteAsync(req_id, code, {silent, user_expressions, timeout})``.

    Resolves with ``{status, execution_count, ename, evalue, user_expressions}``
    from the matching execute_reply. silent defaults to True: no execution
    count, no history, and an error does not abort the kernel's queue.
    """
    req_id, code = args[0], args[1]
    opts = args[2] if len(args) > 2 and isinstance(args[2], dict) else {}
    silent = bool(opts.get("silent", True))
    user_expressions = opts.get("user_expressions")
    if not isinstance(user_expressions, dict):
      user_expressions = {}
    timeout = float(opts.get("timeout") or _RPC_TIMEOUT_SECONDS)

    def _send():
      return self._require_client().execute(
          code,
          silent=silent,
          store_history=not silent,
          user_expressions=user_expressions,
          allow_stdin=False,
          stop_on_error=not silent,
      )

    def _transform(content):
      return {
          "status": content.get("status", "unknown"),
          "execution_count": content.get("execution_count"),
          "ename": content.get("ename"),
          "evalue": content.get("evalue"),
          "user_expressions": content.get("user_expressions") or {},
      }

    self._async_request(req_id, _send, _transform, timeout)

  # --------------------------------------------------------------------
  # Async RPCs (non-blocking; cell code + cursor offset passed from Lua)
  # --------------------------------------------------------------------

  @pynvim.function("JupyterCompleteAsync", sync=False)
  def complete_async(self, args):
    req_id, code, cursor_pos = args[0], args[1], args[2]

    def _transform(content):
      return {
          "matches": [str(m) for m in (content.get("matches") or [])],
          "cursor_start": int(content.get("cursor_start", cursor_pos)),
          "cursor_end": int(content.get("cursor_end", cursor_pos)),
      }

    self._async_request(
        req_id, lambda: self._require_client().complete(code, cursor_pos), _transform
    )

  @pynvim.function("JupyterInspectAsync", sync=False)
  def inspect_async(self, args):
    req_id, code, cursor_pos = args[0], args[1], args[2]

    def _transform(content):
      data = content.get("data")
      return {
          "found": bool(content.get("found", False)),
          "data": dict(data) if isinstance(data, dict) else {},
      }

    self._async_request(
        req_id,
        lambda: self._require_client().inspect(code, cursor_pos, detail_level=0),
        _transform,
    )
