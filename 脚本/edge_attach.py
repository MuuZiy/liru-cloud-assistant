"""Attach to an existing, user-authorized Edge. Standard library only.

The local CDP adapter preserves the PowerShell engine's page WebSocket protocol.
It holds ONE upstream browser connection; status polls and engine restarts never
start Edge, create a profile, or open another upstream authorization session.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICE = "LiruEdgeAttach/1"  # Adapter protocol version, independent of the build tag.
MAX_MESSAGE = 8 * 1024 * 1024
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
SETUP_HINT = "请先正常打开 Edge，在 edge://inspect 左侧点 Remote debugging，允许调试后再点接管；连接授权请在 Edge 中本人确认。"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class AttachError(RuntimeError):
    pass


class AuthorizationPending(AttachError):
    pass


class InvalidSession(AttachError):
    pass


def classroom_url(url):
    try:
        u = urllib.parse.urlsplit(url)
        return (u.scheme in ("http", "https") and u.hostname == "moodle.scnu.edu.cn"
                and not u.username and not u.password and u.port in (None, 80, 443))
    except (ValueError, TypeError):
        return False


def discover_endpoint(data_dir=None):
    # Never write to, initialize, copy, repair, or delete a browser profile.
    if not data_dir and not os.environ.get("LOCALAPPDATA", "").strip():
        raise AttachError("未找到 LOCALAPPDATA；请显式指定已有 Edge 资料目录")
    root = Path(data_dir) if data_dir else Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft/Edge/User Data"
    try:
        with (root / "DevToolsActivePort").open("r", encoding="utf-8") as f:
            data = f.read(4097)
        lines = data.splitlines()
        if len(data) > 4096 or len(lines) != 2:
            raise ValueError()
        port = int(lines[0])
        path = lines[1].strip()
        if not 1 <= port <= 65535 or not re.fullmatch(r"/devtools/browser/[A-Za-z0-9-]{8,100}", path):
            raise ValueError()
        return port, path
    except (OSError, ValueError, UnicodeError):
        raise AttachError(SETUP_HINT) from None


class WebSocket:
    """Bounded RFC6455 text messages, including ping and fragmented UTF-8."""
    def __init__(self, sock, *, client=False, reader=None, buffered=b""):
        self.sock, self.client = sock, client
        self.reader = reader
        self.buffer = bytearray(buffered)
        self.send_lock = threading.Lock()

    @classmethod
    def connect(cls, port, path, timeout=3):
        deadline = time.monotonic() + timeout
        sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        try:
            key = base64.b64encode(os.urandom(16)).decode("ascii")
            request = (f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                       f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                       "Sec-WebSocket-Version: 13\r\n\r\n")
            sock.sendall(request.encode("ascii"))
            data = bytearray()
            while b"\r\n\r\n" not in data:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AttachError("等待 Edge 调试握手超时，请在浏览器中检查授权")
                sock.settimeout(remaining)
                block = sock.recv(4096)
                if not block or len(data) > 16384:
                    raise AttachError("Edge 没有接受调试连接")
                data.extend(block)
            head, rest = bytes(data).split(b"\r\n\r\n", 1)
            lines = head.decode("latin1").split("\r\n")
            headers = dict(line.split(":", 1) for line in lines[1:] if ":" in line)
            headers = {k.lower().strip(): v.strip() for k, v in headers.items()}
            expected = base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")
            if len(lines[0].split()) > 1 and lines[0].split()[1] == "403":
                raise AuthorizationPending("Edge 尚未允许调试连接；请在 Edge 中点击允许远程控制，然后重新运行本入口或再点「接管 Edge」")
            if (lines[0].split()[1] != "101" or headers.get("sec-websocket-accept") != expected
                    or headers.get("upgrade", "").lower() != "websocket"):
                raise AttachError("Edge 拒绝调试连接；请在浏览器中确认授权")
            sock.settimeout(None)
            return cls(sock, client=True, buffered=rest)
        except Exception:
            sock.close()
            raise

    def read(self, n):
        while len(self.buffer) < n:
            block = self.reader.read(n - len(self.buffer)) if self.reader else self.sock.recv(n - len(self.buffer))
            if not block:
                raise AttachError("调试连接已断开；请手动重新接管")
            self.buffer.extend(block)
        result = bytes(self.buffer[:n])
        del self.buffer[:n]
        return result

    def send(self, value, opcode=1):
        data = value.encode("utf-8") if isinstance(value, str) else value
        if len(data) > MAX_MESSAGE:
            raise AttachError("调试消息过大")
        size = len(data)
        header = bytes([0x80 | opcode, (0x80 if self.client else 0) | (size if size < 126 else 126 if size < 65536 else 127)])
        if size >= 126:
            header += struct.pack("!H" if size < 65536 else "!Q", size)
        if self.client:
            mask = os.urandom(4)
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            header += mask
        with self.send_lock:
            self.sock.sendall(header + data)

    def receive(self):
        chunks, total, started = [], 0, False
        while True:
            a, b = self.read(2)
            final, opcode, masked = bool(a & 0x80), a & 15, bool(b & 0x80)
            if a & 0x70 or masked == self.client:
                raise AttachError("调试消息格式无效")
            size = b & 127
            if size == 126:
                size = struct.unpack("!H", self.read(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self.read(8))[0]
            if size > MAX_MESSAGE or (opcode >= 8 and (not final or size > 125)):
                raise AttachError("调试消息长度无效")
            mask = self.read(4) if masked else None
            data = self.read(size)
            if mask:
                data = bytes(v ^ mask[i % 4] for i, v in enumerate(data))
            if opcode == 8:
                raise AttachError("调试连接已断开；请手动重新接管")
            if opcode == 9:
                self.send(data, 10)
                continue
            if opcode == 10:
                continue
            if opcode not in (0, 1) or (opcode == 0 and not started) or (opcode == 1 and started):
                raise AttachError("调试消息类型无效")
            started = True
            chunks.append(data)
            total += size
            if total > MAX_MESSAGE:
                raise AttachError("调试消息过大")
            if final:
                return b"".join(chunks).decode("utf-8")

    def close(self):
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


class BrowserConnection:
    def __init__(self, ws):
        self.ws = ws
        self.lock = threading.RLock()
        self.pending = {}
        self.next_id = 0
        self.closed = False
        threading.Thread(target=self._receive, daemon=True).start()

    def _receive(self):
        try:
            while True:
                obj = json.loads(self.ws.receive())
                with self.lock:
                    wait = self.pending.get(obj.get("id"))
                    if wait:
                        wait[1].append(obj)
                        wait[0].set()
        except Exception:
            self.close()

    def call(self, method, params=None, session=None, timeout=15):
        with self.lock:
            if self.closed:
                raise AttachError("Edge 调试连接已断开，请重新点接管")
            self.next_id += 1
            ident = self.next_id
            event, results = threading.Event(), []
            self.pending[ident] = (event, results)
        try:
            msg = {"id": ident, "method": method, "params": params or {}}
            if session:
                msg["sessionId"] = session
            self.ws.send(json.dumps(msg, ensure_ascii=False))
            if not event.wait(timeout):
                # CDP IDs isolate late replies. A page timeout must not revoke the
                # shared browser session or require another permission prompt.
                raise AttachError("等待浏览器命令响应超时")
            if not results:
                raise AttachError("Edge 调试连接已断开")
            result = results[0]
            if "error" in result:
                message = str(result["error"].get("message", "调试命令失败"))
                error_type = InvalidSession if re.search(
                    r"session (?:with given id not found|closed)|no session with given id|not attached to an active page",
                    message, re.I) else AttachError
                raise error_type(message)
            return result.get("result", {})
        finally:
            with self.lock:
                self.pending.pop(ident, None)

    def close(self):
        with self.lock:
            if self.closed:
                return
            self.closed = True
            self.ws.close()
            for event, _ in self.pending.values():
                event.set()


class Attachment:
    PAGE_METHODS = {"Page.enable", "Runtime.enable", "Runtime.evaluate", "Page.navigate",
                    "Page.bringToFront", "Input.dispatchMouseEvent", "Emulation.setFocusEmulationEnabled"}

    def __init__(self, data_dir=None):
        self.data_dir = data_dir
        self.lock = threading.RLock()
        self.command_lock = threading.RLock()
        self.target_lock = threading.RLock()
        self.browser = None
        self.pending_browser = None
        self.phase = "disconnected"
        self.message = "尚未接管 Edge。" + SETUP_HINT
        self.product = ""
        self.selected = None
        self.session = None
        self.window_id = None
        self.epoch = 0
        self.clients = 0
        self.cancel_connect = threading.Event()

    def status(self):
        with self.lock:
            if self.browser and self.browser.closed and self.phase == "connected":
                self.phase, self.message = "disconnected", "Edge 连接已断开，请手动重新接管"
            return {"service": SERVICE, "state": self.phase, "message": self.message,
                    "connected": self.phase == "connected", "browser_version": self.product}

    def connect(self):
        with self.command_lock, self.lock:
            state = self.status()
            if state["connected"]:
                if not self.clients:
                    self._detach_session()
                    self.selected = self.session = self.window_id = None
                return state
            if self.phase == "connecting":
                return state
            self.epoch += 1
            epoch = self.epoch
            self.cancel_connect = threading.Event()
            cancel = self.cancel_connect
            self.phase, self.message = "connecting", "请在已打开的 Edge 中确认调试连接授权"
        threading.Thread(target=self._connect, args=(epoch, cancel), daemon=True).start()
        return self.status()

    def _connect(self, epoch, cancel):
        browser = None
        try:
            port, path = discover_endpoint(self.data_dir)
            deadline = time.monotonic() + 20
            # Only an explicit connect request gets at most two authorization retries.
            # Status polling never retries, and a denied permission is never bypassed.
            for attempt in range(3):
                if cancel.is_set():
                    return
                try:
                    ws = WebSocket.connect(port, path, timeout=min(3, max(.1, deadline - time.monotonic())))
                    browser = BrowserConnection(ws)
                    break
                except AuthorizationPending:
                    if attempt == 2 or time.monotonic() + 2 >= deadline:
                        raise
                    if cancel.wait(2):
                        return
            with self.lock:
                if epoch != self.epoch:
                    browser.close()
                    return
                self.pending_browser = browser
            info = browser.call("Browser.getVersion", timeout=max(.1, deadline - time.monotonic()))
            product = str(info.get("product", ""))
            if not (product.startswith(("Edg/", "Microsoft Edge/", "HeadlessEdg/"))
                    or re.search(r"\bEdg/[0-9]", str(info.get("userAgent", "")))):
                raise AttachError("发现的调试实例不是 Microsoft Edge，已拒绝接管")
            with self.lock:
                if epoch != self.epoch:
                    browser.close()
                    return
                self.browser, self.product = browser, product
                self.pending_browser = None
                self.selected = self.session = self.window_id = None
                self.phase, self.message = "connected", "已接管现有 Edge；请在一个课堂标签页中打开课程"
        except Exception as exc:
            if browser:
                browser.close()
            with self.lock:
                if epoch == self.epoch:
                    self.pending_browser = None
                    self.phase, self.message = "error", str(exc) if isinstance(exc, AttachError) else "无法连接已有 Edge；请检查调试授权后重试"

    def disconnect(self):
        with self.lock:
            self.epoch += 1
            self.cancel_connect.set()
            browser, self.browser = self.browser, None
            pending, self.pending_browser = self.pending_browser, None
            self.selected = self.session = self.window_id = None
            self.phase, self.message = "disconnected", "已断开接管，Edge 窗口和浏览器资料由你管理"
        if browser:
            browser.close()
        if pending and pending is not browser:
            pending.close()

    def _target_infos(self):
        if not self.status()["connected"]:
            return []
        return self.browser.call("Target.getTargets").get("targetInfos", [])

    def targets(self):
        """Enumerate without binding. Once bound, expose only that classroom tab."""
        with self.target_lock:
            if not self.status()["connected"]:
                return []
            items = self._target_infos()
            allowed = [p for p in items if p.get("type") == "page" and classroom_url(p.get("url", ""))]
            if self.selected is None:
                if len(allowed) > 1:
                    self.message = "检测到多个课堂标签，请只保留一个课堂标签；引擎连接时才会绑定"
                elif allowed:
                    self.message = "Edge 已连接；引擎连接课堂标签时才会绑定"
                else:
                    self.message = "Edge 已连接，请在浏览器中打开砺儒云课堂页面"
                return allowed
            hit = next((p for p in allowed if p.get("targetId") == self.selected), None)
            if not hit:
                self.message = "接管的课堂标签已关闭或离开网站；请恢复该标签，或断开后重新接管"
                return []
            self.message = "已连接课堂标签；停止任务不会关闭你的 Edge"
            return [hit]

    def bind_target(self, target):
        with self.command_lock, self.target_lock:
            if self.selected is not None and target != self.selected:
                raise AttachError("只允许已绑定的课堂标签")
            if not any(p.get("targetId") == target for p in self.targets()):
                raise AttachError("课堂标签不可用，已拒绝绑定")
            self.selected = target

    def _detach_session(self):
        session, self.session = self.session, None
        if session and self.browser and not self.browser.closed:
            try:
                self.browser.call("Target.detachFromTarget", {"sessionId": session}, timeout=2)
            except (AttachError, OSError):
                pass

    def command(self, target, method, params, timeout=30):
        with self.command_lock:
            if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not .1 <= timeout <= 120:
                raise AttachError("调试命令等待时限无效")
            params = dict(params or {})
            href_only = method == "Runtime.evaluate" and params.get("expression") == "location.href"
            # A fixed, side-effect-free URL read lets the existing login wait observe
            # the already bound tab after SSO redirects. No foreign DOM/script access.
            hit = [p for p in self._target_infos() if p.get("targetId") == self.selected and p.get("type") == "page"]
            if (not hit or target != self.selected or
                    (not href_only and not classroom_url(hit[0].get("url", "")))):
                raise AttachError("课堂标签不可用，已拒绝操作其他标签")
            if method == "Target.getTargetInfo":
                if params.get("targetId", target) != target:
                    raise AttachError("不允许访问其他标签")
                return {"targetInfo": hit[0]}
            if method == "Browser.getWindowForTarget":
                if params.get("targetId", target) != target:
                    raise AttachError("不允许访问其他窗口")
                value = self.browser.call(method, {"targetId": target})
                self.window_id = value.get("windowId")
                return value
            if method == "Browser.setWindowBounds":
                if self.window_id is None or params.get("windowId") != self.window_id:
                    raise AttachError("不允许操作其他窗口")
                return self.browser.call(method, params)
            if method not in self.PAGE_METHODS:
                raise AttachError("接管模式不允许此调试命令：" + method)
            if method == "Page.navigate" and not classroom_url(params.get("url", "")):
                raise AttachError("只允许在课堂网站内导航")
            if method == "Runtime.evaluate" and not href_only:
                expr = params.get("expression")
                if not isinstance(expr, str):
                    raise AttachError("页面脚本格式无效")
                params["expression"] = ("if (!/^https?:$/.test(location.protocol) || location.hostname !== 'moodle.scnu.edu.cn') {throw new Error('课堂标签已离开网站');}\n" + expr)
            if not self.session:
                self.session = self.browser.call("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]
            try:
                return self.browser.call(method, params, session=self.session, timeout=timeout)
            except InvalidSession:
                self._detach_session()
                raise


class ParentProcess:
    """Keep the original Windows process handle; PID reuse cannot prolong ownership."""
    def __init__(self, pid):
        import ctypes
        from ctypes import wintypes
        if os.name != "nt" or not isinstance(pid, int) or pid <= 0:
            raise AttachError("接管服务的父进程无效")
        self.pid = pid
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.kernel.OpenProcess.restype = wintypes.HANDLE
        self.kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.kernel.WaitForSingleObject.restype = wintypes.DWORD
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.handle = self.kernel.OpenProcess(0x100000 | 0x1000, False, pid)
        if not self.handle:
            raise AttachError("无法核验控制台父进程，已拒绝保留接管连接")

    def alive(self):
        return bool(self.handle and self.kernel.WaitForSingleObject(self.handle, 0) == 258)

    def close(self):
        if self.handle:
            self.kernel.CloseHandle(self.handle)
            self.handle = None


class AdapterServer(ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = True

    def __init__(self, *args, **kwargs):
        self.owner = None
        self.owner_lock = threading.Lock()
        self.watch_stop = threading.Event()
        self.last_activity = self.last_client_activity = time.monotonic()
        super().__init__(*args, **kwargs)

    def claim_owner(self, pid):
        with self.owner_lock:
            if self.owner and self.owner.pid == pid and self.owner.alive():
                return
            if self.owner and self.owner.alive():
                raise AttachError("接管服务仍由另一个控制台使用，请先正常退出原控制台")
            owner = ParentProcess(pid)
            if not owner.alive():
                owner.close()
                raise AttachError("控制台父进程已退出")
            if self.owner:
                self.owner.close()
            self.owner = owner

    def should_exit(self, now=None):
        now = time.monotonic() if now is None else now
        with self.owner_lock:
            if self.owner and not self.owner.alive():
                return True
        with self.attachment.lock:
            if self.attachment.clients:
                return False
        if now - self.last_client_activity > 12 * 3600:
            return True
        return (self.attachment.status()["state"] not in ("connected", "connecting")
                and now - self.last_activity > 300)

    def watch_lifetime(self):
        while not self.watch_stop.wait(15):
            if self.should_exit():
                self.attachment.disconnect()
                self.shutdown()
                return

    def server_close(self):
        self.watch_stop.set()
        with self.owner_lock:
            if self.owner:
                self.owner.close()
                self.owner = None
        super().server_close()

    def server_bind(self):
        if os.name == 'nt' and hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()

    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)


class AdapterHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 10

    def log_message(self, *args):
        pass

    def permitted(self):
        port = self.server.server_port
        if self.client_address[0] != "127.0.0.1" or self.headers.get("Host") not in (f"127.0.0.1:{port}", f"localhost:{port}"):
            return False
        origin = self.headers.get("Origin")
        return not origin or origin in ("http://127.0.0.1:8765", "http://localhost:8765")

    def reply(self, code, obj):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        try:
            self.server.last_activity = time.monotonic()
            if not self.permitted():
                return self.reply(403, {"error": "forbidden"})
            path = urllib.parse.urlsplit(self.path).path
            attach = self.server.attachment
            if path == "/liru/status":
                return self.reply(200, attach.status())
            if not attach.status()["connected"]:
                return self.reply(503, {"error": "尚未接管 Edge"})
            if path == "/json/version":
                return self.reply(200, {"Browser": attach.product, "Protocol-Version": "1.3", "LiruAttach": SERVICE})
            if path in ("/json", "/json/list"):
                port = self.server.server_port
                return self.reply(200, [{"id": p["targetId"], "type": "page", "title": p.get("title", ""), "url": p["url"],
                                         "webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/liru/page/{p['targetId']}"} for p in attach.targets()])
            if path.startswith("/liru/page/"):
                return self.page_socket(path[len("/liru/page/"):])
            return self.reply(404, {"error": "not found"})
        except (OSError, ValueError, AttachError) as exc:
            if not getattr(self, "upgraded", False):
                try:
                    self.reply(503, {"error": str(exc)})
                except OSError:
                    pass

    def page_socket(self, target):
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", target):
            return self.reply(403, {"error": "只允许已绑定的课堂标签"})
        key = self.headers.get("Sec-WebSocket-Key", "")
        try:
            valid = len(base64.b64decode(key, validate=True)) == 16
        except ValueError:
            valid = False
        if not valid or self.headers.get("Sec-WebSocket-Version") != "13" or self.headers.get("Upgrade", "").lower() != "websocket":
            return self.reply(400, {"error": "invalid websocket"})
        try:
            self.server.attachment.bind_target(target)
        except AttachError as exc:
            return self.reply(403, {"error": str(exc)})
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii"))
        self.end_headers()
        self.upgraded = True
        self.connection.settimeout(None)
        ws = WebSocket(self.connection, reader=self.rfile)
        with self.server.attachment.lock:
            self.server.attachment.clients += 1
            self.server.last_client_activity = time.monotonic()
        try:
            while True:
                request = json.loads(ws.receive())
                self.server.last_client_activity = time.monotonic()
                if not isinstance(request, dict) or not isinstance(request.get("id"), int):
                    raise AttachError("命令格式无效")
                result = {"id": request["id"]}
                try:
                    params = request.get("params", {})
                    if not isinstance(params, dict):
                        raise AttachError("命令参数格式无效")
                    timeout_ms = request.get("liruTimeoutMs", 30000)
                    if isinstance(timeout_ms, bool) or not isinstance(timeout_ms, (int, float)):
                        raise AttachError("调试命令等待时限无效")
                    result["result"] = self.server.attachment.command(target, request.get("method", ""), params, timeout=timeout_ms / 1000)
                except (AttachError, ValueError, KeyError) as exc:
                    result["error"] = {"code": -32000, "message": str(exc)}
                ws.send(json.dumps(result, ensure_ascii=False))
        except (AttachError, OSError, ValueError, UnicodeError):
            pass
        finally:
            with self.server.attachment.lock:
                self.server.attachment.clients -= 1
                self.server.last_client_activity = time.monotonic()
            self.close_connection = True

    def do_POST(self):
        self.server.last_activity = time.monotonic()
        if not self.permitted() or self.headers.get("Content-Type", "").split(";")[0] != "application/json":
            return self.reply(403, {"error": "forbidden"})
        try:
            size = int(self.headers.get("Content-Length", "-1"))
            if not 0 <= size <= 1024:
                raise ValueError()
            body = json.loads(self.rfile.read(size))
            if not isinstance(body, dict):
                raise ValueError()
        except (ValueError, UnicodeError):
            return self.reply(400, {"error": "invalid body"})
        if self.path == "/liru/claim":
            try:
                pid = body.get("parent_pid")
                if isinstance(pid, bool):
                    raise AttachError("接管服务的父进程无效")
                self.server.claim_owner(pid)
            except AttachError as exc:
                return self.reply(409, {"error": str(exc)})
            return self.reply(200, self.server.attachment.status())
        if self.path == "/liru/connect":
            return self.reply(200, self.server.attachment.connect())
        if self.path in ("/liru/disconnect", "/liru/shutdown"):
            self.server.attachment.disconnect()
            self.reply(200, self.server.attachment.status())
            if self.path.endswith("shutdown"):
                threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        self.reply(404, {"error": "not found"})


def local_request(port, action="status", timeout=0.4, payload=None):
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise AttachError("本机接管端口无效")
    req = urllib.request.Request(f"http://127.0.0.1:{port}/liru/{action}")
    if action != "status":
        req.data = json.dumps(payload or {}).encode("utf-8")
        req.add_header("Content-Type", "application/json")
    with OPENER.open(req, timeout=timeout) as response:
        obj = json.loads(response.read(65536))
    if obj.get("service") != SERVICE:
        raise AttachError("端口被其他服务占用，已拒绝连接")
    return obj


def configured_port():
    try:
        with Path(__file__).with_name("配置.json").open(encoding="utf-8-sig") as f:
            cfg = json.load(f)
        value = cfg.get("edge_attach_port", 9232)
        if isinstance(value, bool):
            raise ValueError()
        port = int(value)
        if not 1 <= port <= 65535:
            raise ValueError()
        return port
    except FileNotFoundError:
        return 9232
    except (OSError, ValueError, AttributeError):
        raise AttachError("配置中的 edge_attach_port 必须是 1 到 65535 的端口") from None


def ensure_service(port=9232, data_dir=None, parent_pid=None):
    try:
        state = local_request(port)
    except Exception:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                raise AttachError("本机接管端口已被占用；不会关闭或接管未知服务")
        except OSError:
            pass
    else:
        if parent_pid is not None:
            return local_request(port, "claim", timeout=2, payload={"parent_pid": parent_pid})
        return state
    args = [sys.executable, str(Path(__file__).resolve()), "--serve", "--port", str(port)]
    if data_dir:
        args += ["--data-dir", str(data_dir)]
    if parent_pid is not None:
        args += ["--parent-pid", str(parent_pid)]
    proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            creationflags=0x08000000 if os.name == "nt" else 0,
                            env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))
    for _ in range(30):
        try:
            return local_request(port)
        except Exception:
            if proc.poll() is not None:
                break
            time.sleep(0.1)
    raise AttachError("无法启动本机接管连接服务；没有启动或修改 Edge")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--connect", action="store_true")
    parser.add_argument("--disconnect", action="store_true")
    parser.add_argument("--port", type=int)
    parser.add_argument("--data-dir")
    parser.add_argument("--parent-pid", type=int)
    args = parser.parse_args()
    try:
        if args.port is None:
            args.port = configured_port()
        if not 1 <= args.port <= 65535:
            raise AttachError("接管端口必须在 1 到 65535 之间")
    except AttachError as exc:
        print(str(exc))
        return 1
    if args.serve:
        try:
            server = AdapterServer(("127.0.0.1", args.port), AdapterHandler)
        except OSError:
            print("接管服务端口被占用或暂未释放；没有启动或修改 Edge")
            return 1
        server.attachment = Attachment(args.data_dir)
        try:
            if args.parent_pid is not None:
                server.claim_owner(args.parent_pid)
        except AttachError as exc:
            server.server_close()
            print(str(exc))
            return 1
        threading.Thread(target=server.watch_lifetime, daemon=True).start()
        try:
            server.serve_forever(poll_interval=0.2)
        finally:
            server.attachment.disconnect()
            server.server_close()
        return 0
    try:
        if args.disconnect:
            state = local_request(args.port, "disconnect", timeout=2)
        elif args.connect:
            ensure_service(args.port, args.data_dir)
            state = local_request(args.port, "connect", timeout=2)
        else:
            state = local_request(args.port)
        print(json.dumps(state, ensure_ascii=False))
        return int(state["state"] == "error")
    except Exception as exc:
        print(str(exc) if isinstance(exc, AttachError) else "尚未连接接管服务，请先在控制台点接管 Edge")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
