import queue
import threading
from concurrent.futures import Future
from pathlib import Path

import pynvim
from jupyter_client import BlockingKernelClient
from jupyter_core.paths import jupyter_runtime_dir

CompletionItemKind = {
    "text": 1,
    "method": 2,
    "function": 3,
    "constructor": 4,
    "field": 5,
    "variable": 6,
    "class": 7,
    "interface": 8,
    "module": 9,
    "property": 10,
    "unit": 11,
    "value": 12,
    "enum": 13,
    "keyword": 14,
    "snippet": 15,
    "color": 16,
    "file": 17,
    "reference": 18,
    "folder": 19,
    "enumMember": 20,
    "constant": 21,
    "struct": 22,
    "event": 23,
    "operator": 24,
    "typeParameter": 25,
    # Jupyter specific
    "dict key": 14,
    "instance": 6,
    "magic": 23,
    "path": 19,
    "statement": 13
}

_RPC_TIMEOUT_SECONDS = 60.0


class _Worker:
  """Single daemon thread that owns the BlockingKernelClient.

  jupyter_client's ZMQ sockets are thread-affine, so every client operation
  (attach / execute / complete / inspect) is funnelled through one thread via
  a FIFO queue. Jobs run serially, which also serializes channel reads without
  an explicit lock. Sync RPCs block on the returned Future; async RPCs attach
  a done-callback (invoked on this worker thread).
  """

  def __init__(self):
    self._q: "queue.Queue" = queue.Queue()
    self._thread = threading.Thread(
        target=self._run, name="jupyter-kernel-worker", daemon=True
    )
    self._thread.start()

  def _run(self):
    while True:
      fn, fut = self._q.get()
      if fn is None:
        return
      if fut.set_running_or_notify_cancel():
        try:
          fut.set_result(fn())
        except BaseException as exc:  # noqa: BLE001 - propagate to caller
          fut.set_exception(exc)

  def submit(self, fn) -> "Future":
    fut: "Future" = Future()
    self._q.put((fn, fut))
    return fut


@pynvim.plugin
class JupyterKernel:

  def __init__(self, vim):
    self.vim: pynvim.Nvim = vim
    self.client: BlockingKernelClient | None = None
    self.kerneldir = Path(jupyter_runtime_dir())
    self._worker = _Worker()

  # --------------------------------------------------------------------
  # Worker helpers
  # --------------------------------------------------------------------

  def _run_sync(self, fn, timeout=_RPC_TIMEOUT_SECONDS):
    return self._worker.submit(fn).result(timeout=timeout)

  def _on_async_done(self, req_id, future):
    try:
      result = future.result()
    except BaseException as exc:  # noqa: BLE001
      self._dispatch_resolve(req_id, str(exc), None)
      return
    self._dispatch_resolve(req_id, None, result)

  def _dispatch_resolve(self, req_id, err, result):
    # Bounce onto nvim's main loop, then into Lua. Runs from the worker thread.
    self.vim.async_call(self._resolve, req_id, err, result)

  def _resolve(self, req_id, err, result):
    self.vim.exec_lua(
        "require('jupyter_kernel.async')._resolve(...)", req_id, err, result
    )

  # --------------------------------------------------------------------
  # Kernel discovery / lifecycle
  # --------------------------------------------------------------------

  @pynvim.function("JupyterKernels", sync=True)
  def running_kernels(self, args):
    del args
    kernels = self.kerneldir.glob('kernel-*.json')
    kernels = sorted(kernels, reverse=True, key=lambda f: f.stat().st_ctime)
    return [kern.name for kern in kernels]

  @pynvim.function("JupyterAttach")
  def attach(self, args):
    kernel = args[0]

    def _do_attach():
      if self.client is not None:
        self.client.stop_channels()
      client = BlockingKernelClient()
      client.load_connection_file(self.kerneldir / kernel)
      client.start_channels()
      self.client = client

    self._run_sync(_do_attach)

  @pynvim.function('JupyterDetach')
  def detach(self, args):
    del args

    def _do_detach():
      if self.client is not None:
        self.client.stop_channels()
        self.client = None

    self._run_sync(_do_detach)
    self.vim.command("let b:jupyter_attached = v:false")
    self.vim.command('echo "Jupyter kernel detached"')

  # --------------------------------------------------------------------
  # Sync RPCs (kept for backward-compat; read cursor on the main thread)
  # --------------------------------------------------------------------

  @pynvim.function('JupyterComplete', sync=True)
  def complete(self, args):
    timeout = args[0]
    line_content = self.vim.current.line
    _row, col = self.vim.current.window.cursor

    def _do():
      assert self.client is not None, "No jupyter kernel attached"
      return self.client.complete(
          line_content, col, reply=True, timeout=timeout
      )['content']

    try:
      reply = self._run_sync(_do, timeout=timeout + 5)
      return self._parse_completion_reply(reply)
    except TimeoutError:
      self.vim.out_write("Jupyter kernel completion timeout\n")
      return {}
    except Exception as e:
      self.vim.out_write(f"Jupyter kernel's exception: {e}\n")
      return {}

  def _parse_completion_reply(self, reply):
    has_experimental_types = "metadata" in reply and (
        '_jupyter_types_experimental' in reply['metadata'])
    if not has_experimental_types:
      return [{"label": m} for m in reply["matches"]]

    return [
        {
            "label": match.get("text", ""),
            "documentation": {
                "kind": "markdown",
                "value": f"```python\n{match.get('signature', '')}\n```"
            },
            # default kind: text = 1
            "kind": CompletionItemKind[match.get("type", "text")]
        } for match in reply['metadata']['_jupyter_types_experimental']
    ]

  @pynvim.function("JupyterInspect", sync=True)
  def inspect(self, args):
    timeout = args[0]
    line_content = self.vim.current.line
    _row, col = self.vim.current.window.cursor

    def _do():
      assert self.client is not None, "No jupyter kernel attached"
      return self.client.inspect(
          line_content, col, detail_level=0, reply=True, timeout=timeout
      )['content']

    try:
      return self._run_sync(_do, timeout=timeout + 5)
    except TimeoutError:
      return {'status': "_Kernel timeout_"}
    except Exception as exception:
      return {'status': f"_{str(exception)}_"}

  @pynvim.function("JupyterExecute", sync=True)
  def execute(self, args):
    code = args[0]

    def _do():
      assert self.client is not None, "No jupyter kernel attached"
      self.client.execute(code, silent=False)
      return "ok"

    try:
      return self._run_sync(_do)
    except Exception as e:
      return f"Exception: {str(e)}"

  # --------------------------------------------------------------------
  # Async RPCs (non-blocking; cell code + cursor offset passed from Lua)
  # --------------------------------------------------------------------

  @pynvim.function("JupyterCompleteAsync", sync=False)
  def complete_async(self, args):
    req_id, code, cursor_pos = args[0], args[1], args[2]

    def _do():
      assert self.client is not None, "No jupyter kernel attached"
      content = self.client.complete(
          code, cursor_pos, reply=True, timeout=_RPC_TIMEOUT_SECONDS
      )['content']
      return {
          "matches": [str(m) for m in (content.get("matches") or [])],
          "cursor_start": int(content.get("cursor_start", cursor_pos)),
          "cursor_end": int(content.get("cursor_end", cursor_pos)),
      }

    self._worker.submit(_do).add_done_callback(
        lambda f: self._on_async_done(req_id, f)
    )

  @pynvim.function("JupyterInspectAsync", sync=False)
  def inspect_async(self, args):
    req_id, code, cursor_pos = args[0], args[1], args[2]

    def _do():
      assert self.client is not None, "No jupyter kernel attached"
      content = self.client.inspect(
          code, cursor_pos, detail_level=0, reply=True, timeout=_RPC_TIMEOUT_SECONDS
      )['content']
      data = content.get("data")
      return {
          "found": bool(content.get("found", False)),
          "data": dict(data) if isinstance(data, dict) else {},
      }

    self._worker.submit(_do).add_done_callback(
        lambda f: self._on_async_done(req_id, f)
    )
