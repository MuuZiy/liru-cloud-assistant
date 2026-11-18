"""砺儒云课堂 · 刷课控制台（网页版）

引擎：同目录的 auto_course.ps1 —— Edge 调试端口方案，浏览器最小化也能正常跑，
      不抢鼠标、不占屏幕。本文件只负责：起 / 停 / 接管已有 Edge + 解析运行日志
      成进度与告警，交给 ui/index.html 显示。

用法：python webui.py   然后浏览器打开 http://127.0.0.1:8765
      （正常使用请双击上级目录的「打开控制台.bat」）
"""
import copy
import edge_attach
import webui_core as core
from webui_log import humanize, short_chapter, to_pct
from webui_core import lecture_no
from webui_log_reader import IncrementalLogReader
import ctypes
import json
import math
from datetime import datetime
import os
import re
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PS1 = os.path.join(HERE, "auto_course.ps1")
CONF = os.path.join(HERE, "配置.json")
PACE_FILE = os.path.join(HERE, "请求节奏.json")
LOGFILE = os.path.join(HERE, "运行日志.txt")
PIDFILE = os.path.join(HERE, "run.pid")
STOPFLAG = os.path.join(HERE, "stop.flag")
PAGE_HTML = os.path.join(HERE, "ui", "index.html")
WEB_PID_FILE = os.path.join(HERE, "webui.pid")
COURSE_FILE = os.path.join(HERE, "课程结构.json")      # 引擎写的整门课章节结构

# 防休眠：引擎运行期间保持"系统 + 屏幕"不休眠（挂机刷课的前提）
ES_CONTINUOUS = 0x80000000
ES_SYSTEM_REQUIRED = 0x00000001
ES_DISPLAY_REQUIRED = 0x00000002

HOST, PORT = "127.0.0.1", 8765
DEFAULT_DEBUG_PORT = 9232  # 本机兼容层；已有 Edge 的实际端口从 DevToolsActivePort 读取
# 代码版本标记（随改动递增）：用于确认 8765 上跑的到底是哪一版代码
BUILD_TAG = "2026-11-18-r89"
# 后端能力清单，随 /api/status 一起下发。前端据此判断"我要用的这个接口在不在"。
# 为什么需要它：**页面是每次 GET / 从磁盘读的，刷新一下就是最新的；后端却是常驻进程**，
# 改了 webui.py 不重启它就一直跑旧代码。于是会出现"页面上有新按钮、后端还不认识这个接口"
# 的错位 —— 用户点了才发现，还只看到一句 "unknown action"（真人踩过一次）。
# 有了 caps，页面能**提前**把按钮禁掉并写明原因（重启控制台即可）。
CAPS = ("scan", "attach_edge")

k32 = ctypes.windll.kernel32
# 显式声明 HANDLE，避免 64 位 Python 默认 c_int 截断句柄。
from ctypes import wintypes
k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
k32.OpenProcess.restype = wintypes.HANDLE
k32.CloseHandle.argtypes = [wintypes.HANDLE]
k32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
k32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
k32.WaitForSingleObject.restype = wintypes.DWORD
k32.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
k32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD,
                                         wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
k32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
k32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
k32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.c_void_p]
k32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.c_void_p]
_shell32 = ctypes.windll.shell32
_shell32.CommandLineToArgvW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_int)]
_shell32.CommandLineToArgvW.restype = ctypes.POINTER(wintypes.LPWSTR)
k32.LocalFree.argtypes = [ctypes.c_void_p]
k32.LocalFree.restype = ctypes.c_void_p
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
DETACHED_PROCESS = 0x00000008
CREATE_NEW_PROCESS_GROUP = 0x00000200
CREATE_NO_WINDOW = 0x08000000
STILL_ACTIVE = 259
_stop_lock = threading.Lock()
# start / scan / stop / attach-edge 串行化：两个请求同时通过“没在运行”检查，
# 会各起一个引擎；停止流程也会和启动流程抢 run.pid。RLock 允许内部嵌套调用。
_run_lock = threading.RLock()
_console_closing = False


def _serialized(fn):
    def wrapped(*args, **kwargs):
        with _run_lock:
            if _console_closing and fn.__name__ != 'stop_run':
                return False, '控制台正在关闭，请等待退出后重新打开'
            return fn(*args, **kwargs)
    return wrapped


# ---- Windows 作业对象：控制台进程无论怎么死（X/强杀/崩溃），引擎必被内核终止 ----
# 根治历史问题：强杀控制台后引擎变孤儿继续空转（2026-09-15 的"残留脚本"事故）。
class _IO_COUNTERS(ctypes.Structure):
    _fields_ = [(f, ctypes.c_ulonglong) for f in
                ("ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                 "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]


class _BASIC_LIMIT_INFO(ctypes.Structure):
    _fields_ = [("PerProcessUserTimeLimit", ctypes.c_longlong),
                ("PerJobUserTimeLimit", ctypes.c_longlong),
                ("LimitFlags", ctypes.c_uint32),
                ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t),
                ("ActiveProcessLimit", ctypes.c_uint32),
                ("Affinity", ctypes.c_size_t),
                ("PriorityClass", ctypes.c_uint32),
                ("SchedulingClass", ctypes.c_uint32)]


class _EXT_LIMIT_INFO(ctypes.Structure):
    _fields_ = [("BasicLimitInformation", _BASIC_LIMIT_INFO),
                ("IoInfo", _IO_COUNTERS),
                ("ProcessMemoryLimit", ctypes.c_size_t),
                ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t),
                ("PeakJobMemoryUsed", ctypes.c_size_t)]


_JOB_LIMIT_KILL_ON_CLOSE = 0x00002000
_JOB_LIMIT_SILENT_BREAKAWAY = 0x00000800
_JOB_OBJECT_EXTENDED_LIMIT = 9
_engine_job = None                                  # 模块级持有：句柄活 = 约束活


def _job_for_engine():
    """懒创建引擎作业对象（整个控制台生命周期共用一个，引擎每次启动都挂进来）。

    SILENT_BREAKAWAY_OK 必须开：引擎的子进程要能静默脱离作业 —— 否则走 .bat
    直接刷课时引擎自己拉起的 Edge 也会进作业，控制台一死连用户的已接管 Edge
    都被连坐杀掉（2026-09-16 推演出来的坑）。开了它，只有引擎本身受约束。"""
    global _engine_job
    if _engine_job:
        return _engine_job
    try:
        k32.CreateJobObjectW.restype = ctypes.c_void_p
        job = k32.CreateJobObjectW(None, None)
        if not job:
            return None
        ext = _EXT_LIMIT_INFO()
        ext.BasicLimitInformation.LimitFlags = (_JOB_LIMIT_KILL_ON_CLOSE |
                                                _JOB_LIMIT_SILENT_BREAKAWAY)
        if not k32.SetInformationJobObject(ctypes.c_void_p(job), _JOB_OBJECT_EXTENDED_LIMIT,
                                           ctypes.byref(ext), ctypes.sizeof(ext)):
            return None
        _engine_job = job
    except Exception:  # noqa: BLE001
        _engine_job = None
    return _engine_job


def _bind_job(proc):
    """把已启动的引擎进程挂进作业。失败不致命（老系统可能禁嵌套），只放弃这层保险。"""
    job = _job_for_engine()
    if not job:
        return False
    try:
        return bool(k32.AssignProcessToJobObject(ctypes.c_void_p(job),
                                                 ctypes.c_void_p(int(proc._handle))))
    except Exception:  # noqa: BLE001
        return False


def keep_awake_loop():
    """引擎在跑就保持系统/屏幕唤醒；停了就恢复（线程退出时标志自动失效）。"""
    while True:
        try:
            if engine_alive():
                k32.SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)
            else:
                k32.SetThreadExecutionState(ES_CONTINUOUS)
        except Exception:  # noqa: BLE001
            pass
        time.sleep(30)


# ---------------- 基础 ----------------
def sys32(name):
    root = os.environ.get("SystemRoot", r"C:\Windows")
    p = os.path.join(root, "System32", name)
    return p if os.path.exists(p) else name


def ps_exe():
    return sys32(os.path.join("WindowsPowerShell", "v1.0", "powershell.exe"))


def alive(pid):
    if not pid:
        return False
    h = k32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
    if not h:
        return False
    code = ctypes.c_ulong()
    ok = k32.GetExitCodeProcess(h, ctypes.byref(code))
    k32.CloseHandle(h)
    return bool(ok) and code.value == STILL_ACTIVE


def read_text(path, limit=None):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except (FileNotFoundError, OSError):
        return []
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        # 引擎可能正写到一半（最后半个字符）；先按替换字符读，
        # 只有确实大面积不是 UTF-8 时，才回退 GBK 老日志。
        text = data.decode("utf-8-sig", errors="replace")
        if text.count("\ufffd") > 8:
            try:
                text = data.decode("gbk")
            except UnicodeDecodeError:
                pass
    lines = text.splitlines()
    return lines[-limit:] if limit else lines


# ---------------- 引擎状态 / 控制 ----------------
def run_pid():
    try:
        with open(PIDFILE, encoding="ascii") as f:
            return int(f.read().strip())
    except Exception:  # noqa: BLE001
        return None


def _engine_args(cmd):
    """只接受实际 -File 参数和本目录绝对路径；命令正文/同名副本均不算。"""
    if not isinstance(cmd, str) or not cmd.strip():
        return None
    argc = ctypes.c_int()
    ptr = _shell32.CommandLineToArgvW(cmd.strip(), ctypes.byref(argc))
    if not ptr:
        return None
    try:
        args = [ptr[i] for i in range(argc.value)]
    finally:
        k32.LocalFree(ptr)
    if not args or os.path.basename(args[0]).lower() not in ('powershell.exe', 'pwsh.exe', 'powershell', 'pwsh'):
        return None
    i = 1
    while i < len(args):
        flag = args[i].lower()
        if flag == '-file':
            if i + 1 >= len(args):
                return None
            path = args[i + 1]
            if os.path.isabs(path) and os.path.normcase(os.path.normpath(path)) == os.path.normcase(PS1):
                return args[i + 2:]
            return None
        if flag in ('-noprofile', '-nologo', '-noninteractive', '-noexit', '-sta', '-mta'):
            i += 1
        elif flag in ('-executionpolicy', '-windowstyle', '-inputformat', '-outputformat') and i + 1 < len(args):
            i += 2
        else:
            return None
    return None


def is_engine_cmd(cmd):
    return _engine_args(cmd) is not None


def _is_attach_process(cmd):
    args = _engine_args(cmd) or []
    i = 0
    while i < len(args):
        flag = args[i].lower()
        if flag in ('-attachedge', '-attachedge:$true'):
            return True
        i += 2 if flag in ('-configpath', '-limit', '-scope', '-chapter') else 1
    return False


def engine_alive():
    """run.pid 可能被系统复用；只认「PID 活着且命令行确实是引擎」的那一个。"""
    p = run_pid()
    cmd = _process_cmdline(p) if p and alive(p) else ''
    return bool(cmd and is_engine_cmd(cmd) and not _is_attach_process(cmd))


# ---------------- 进程扫描：找出所有在跑的刷课脚本 ----------------
# run.pid 只能代表"控制台自己启动的那一个"。如果控制台被强制关闭过、或有人直接
# 双击了 2-开始刷课.bat，就会有一个"不受控"的脚本在跑：控制台既看不见也停不掉。
# （2026-09-15 就有一个这样的脚本带着旧代码空转了两小时、刷了 2000+ 行日志。）
# 所以这里直接扫进程——纯 ctypes，不依赖 wmic / PowerShell。
_ntdll = ctypes.windll.ntdll
_ntdll.NtQueryInformationProcess.argtypes = [wintypes.HANDLE, ctypes.c_int,
    ctypes.c_void_p, wintypes.ULONG, ctypes.POINTER(wintypes.ULONG)]
TH32CS_SNAPPROCESS = 0x00000002
PROCESS_CMD_LINE_INFORMATION = 60
_ENGINE_SCRIPT = "auto_course.ps1"


class _UNICODE_STRING(ctypes.Structure):
    _fields_ = [("Length", ctypes.c_ushort),
                ("MaximumLength", ctypes.c_ushort),
                ("Buffer", ctypes.c_void_p)]


class _PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [("dwSize", ctypes.c_ulong), ("cntUsage", ctypes.c_ulong),
                ("th32ProcessID", ctypes.c_ulong), ("th32DefaultHeapID", ctypes.c_void_p),
                ("th32ModuleID", ctypes.c_ulong), ("cntThreads", ctypes.c_ulong),
                ("th32ParentProcessID", ctypes.c_ulong), ("pcPriClassBase", ctypes.c_long),
                ("dwFlags", ctypes.c_ulong), ("szExeFile", ctypes.c_wchar * 260)]


def _cmdline_from_handle(h):
    try:
        need = ctypes.c_ulong(0)
        _ntdll.NtQueryInformationProcess(h, PROCESS_CMD_LINE_INFORMATION, None, 0,
                                         ctypes.byref(need))
        size = need.value or 8192
        buf = ctypes.create_string_buffer(size)
        if _ntdll.NtQueryInformationProcess(h, PROCESS_CMD_LINE_INFORMATION, buf, size,
                                            ctypes.byref(need)) != 0:
            return ""
        us = ctypes.cast(buf, ctypes.POINTER(_UNICODE_STRING)).contents
        if not us.Buffer or us.Length == 0:
            return ""
        return ctypes.wstring_at(us.Buffer, us.Length // 2)
    except Exception:  # noqa: BLE001
        return ""


def _process_cmdline(pid):
    h = k32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
    if not h:
        return ""
    try:
        return _cmdline_from_handle(h)
    finally:
        k32.CloseHandle(h)


def _pin_engine(pid):
    """身份核验与后续停止共用一个句柄，PID 被复用也不会转向新进程。"""
    h = k32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | 0x100000 | 0x0001, False, int(pid))
    if not h:
        return None
    keep = False
    try:
        buf, size = ctypes.create_unicode_buffer(32768), wintypes.DWORD(32768)
        cmd = _cmdline_from_handle(h)
        if (k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size))
                and os.path.basename(buf.value).lower() in ('powershell.exe', 'pwsh.exe')
                and is_engine_cmd(cmd) and k32.WaitForSingleObject(h, 0) == 258):
            keep = True
            return {'pid': pid, 'handle': h, 'launcher': _is_attach_process(cmd)}
        return None
    finally:
        if not keep:
            k32.CloseHandle(h)


def _pinned_running(proc):
    # WAIT_FAILED 也不能宣称已结束；保留现场并向使用者报错。
    return k32.WaitForSingleObject(proc['handle'], 0) != 0


def _terminate_pinned(proc):
    # 只终止核验过的引擎本体；不递归结束它可能启动的已接管 Edge。
    return bool(k32.TerminateProcess(proc['handle'], 1))


_engines = {"t": 0.0, "v": []}


def engine_processes(max_age=5.0, force=False):
    """正在运行 auto_course.ps1 的进程 → [{"pid":int,"cmd":str}]（默认 5 秒缓存）

    扫描一次约 30ms；轮询是 3 秒一次，缓存必须比轮询长，否则等于每轮都扫。

    只对 powershell/pwsh 进程取命令行，几百个进程里通常只查两三个，开销可忽略。
    """
    if not force and time.time() - _engines["t"] < max_age:
        # 进程退出不会主动通知缓存：命中缓存前先确认那些 PID 还活着且仍是引擎。
        # 不确认的话，引擎刚结束的 5 秒里会被当成"残留脚本"，开始/识别按钮跟着禁用。
        cached = _engines["v"]
        if all(alive(e["pid"]) and is_engine_cmd(_process_cmdline(e["pid"])) for e in cached):
            return cached
        _engines["t"] = 0.0
    found = []
    try:
        snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
        pe = _PROCESSENTRY32W()
        pe.dwSize = ctypes.sizeof(_PROCESSENTRY32W)
        if k32.Process32FirstW(snap, ctypes.byref(pe)):
            while True:
                exe = (pe.szExeFile or "").lower()
                if exe in ("powershell.exe", "pwsh.exe"):
                    cmd = _process_cmdline(pe.th32ProcessID)
                    if is_engine_cmd(cmd):
                        found.append({"pid": int(pe.th32ProcessID), "cmd": cmd})
                if not k32.Process32NextW(snap, ctypes.byref(pe)):
                    break
        k32.CloseHandle(snap)
    except Exception:  # noqa: BLE001
        pass
    _engines["t"] = time.time()
    _engines["v"] = found
    return found


_active_scan = {"pid": 0, "proc": None}
_scan_lock = threading.RLock()
_scan_handoff = {}
_owned_engines = {}                 # Popen 句柄保护所有本控制台启动的引擎，不只扫描


def _owned_engine_pids(include_launchers=True):
    with _scan_lock:
        for pid, entry in list(_owned_engines.items()):
            if entry['proc'].poll() is not None:
                del _owned_engines[pid]
        return {pid for pid, e in _owned_engines.items()
                if include_launchers or not e['launcher']}


def scan_alive():
    """本控制台刚起的识别进程。

    引擎要等 PowerShell 启动、写完 run.pid 才会被 engine_alive() 认出来；
    在那几秒里 stray_engines() 会把它当成“残留脚本”，前端于是把所有按钮
    （包括范围）锁死。记住 spawn 出来的 PID，先把它从残留里排除。
    """
    with _scan_lock:
        pid = int(_active_scan.get("pid") or 0)
        if not pid:
            return False
        proc = _active_scan.get("proc")
        if proc is not None and getattr(proc, "pid", None) == pid:
            # Our Popen handle is authoritative, including before PowerShell's
            # command line becomes readable. poll also prevents PID reuse.
            active = proc.poll() is None
        else:
            active = alive(pid) and is_engine_cmd(_process_cmdline(pid))
        if not active:
            _active_scan.update(pid=0, proc=None)
        return bool(active)


def stray_engines():
    """不受本控制台管理的刷课脚本（run.pid 之外的）。排除"只开已接管 Edge"的短命进程。"""
    out = []
    engines = engine_processes()
    # Take the scan PID after enumeration, under the spawn-registration lock.
    # Otherwise a status poll can enumerate a just-spawned scan as a stray.
    with _scan_lock:
        tracked = run_pid()
        owned = _owned_engine_pids()
        scan = int(_active_scan.get("pid") or 0) if scan_alive() else 0
        for e in engines:
            if e["pid"] == tracked or e["pid"] == scan or e['pid'] in owned:
                continue
            if _is_attach_process(e["cmd"]):
                continue
            out.append(e)
    return out


STRAY_CONFIRM_SECONDS = 15.0
STRAY_RETRY_SECONDS = 60.0
_stray_cleanup_lock = threading.RLock()
_stray_candidates = {}


def _forget_stray(pid):
    record = _stray_candidates.pop(pid, None)
    if record and record.get('proc'):
        k32.CloseHandle(record['proc']['handle'])


def _auto_cleanup_state(pids):
    with _stray_cleanup_lock:
        return {pid: _stray_candidates[pid]['state'] for pid in pids if pid in _stray_candidates}


def _cleanup_run_pid():
    """0=确实没有 PID 文件；None=读取失败/半写，自动清理必须暂停。"""
    try:
        with open(PIDFILE, encoding='ascii') as f:
            pid = int(f.read().strip())
        return pid if pid > 0 else None
    except FileNotFoundError:
        return 0
    except (OSError, ValueError, UnicodeError):
        return None


def cleanup_strays_once():
    """后台一步：跨轮次持有原进程句柄，确认 15 秒后仅清理仍未被管理的实例。

    不调用 stop_run、不写 stop.flag、不删除 run.pid，不接触正常运行者与 Edge。
    启动/手动停止使用同一 _run_lock；HTTP 状态读取不会触发清理。
    """
    with _run_lock, _stray_cleanup_lock:
        now = time.monotonic()
        tracked = _cleanup_run_pid()
        if tracked is None:
            for pid in list(_stray_candidates):
                _forget_stray(pid)
            return
        candidates = {e['pid']: e for e in stray_engines() if e['pid'] != tracked}
        for pid, record in list(_stray_candidates.items()):
            ended = record.get('proc') and not _pinned_running(record['proc'])
            if pid not in candidates or ended:
                if ended and record['state'] == 'stopping':
                    print('auto-cleanup: 已结束残留引擎 PID %s' % pid, flush=True)
                _forget_stray(pid)
                _engines['t'] = 0.0
                candidates.pop(pid, None)
        for pid in candidates:
            record = _stray_candidates.get(pid)
            if record and now < record['retry_at']:
                continue
            if record is None:
                record = {'proc': None, 'since': now, 'retry_at': 0.0, 'state': 'waiting'}
                _stray_candidates[pid] = record
            if record['proc'] is None:
                proc = _pin_engine(pid)
                if not proc or proc['launcher']:
                    if proc:
                        k32.CloseHandle(proc['handle'])
                    record.update(state='failed', retry_at=now + STRAY_RETRY_SECONDS)
                    continue
                record.update(proc=proc, since=now, state='waiting')
            if now - record['since'] < STRAY_CONFIRM_SECONDS:
                continue
            # 即使候选早已确认，终止前仍重读管理身份；独立 bat 可以刚写完 run.pid。
            with _scan_lock:
                tracked = _cleanup_run_pid()
                protected = _owned_engine_pids() | {tracked}
                if scan_alive():
                    protected.add(_active_scan['pid'])
                if tracked is None or pid in protected:
                    _forget_stray(pid)
                    continue
                proc = record['proc']
                cmd = _cmdline_from_handle(proc['handle'])
                if not is_engine_cmd(cmd) or _is_attach_process(cmd):
                    k32.CloseHandle(proc['handle'])
                    record.update(proc=None, state='failed', retry_at=now + STRAY_RETRY_SECONDS)
                    continue
                if not _pinned_running(proc):
                    _forget_stray(pid)
                    continue
                ok = _terminate_pinned(proc)
                record.update(state='stopping' if ok else 'failed', retry_at=now + STRAY_RETRY_SECONDS)
                _engines['t'] = 0.0
                if not ok:
                    print('auto-cleanup: 残留引擎 PID %s 未能结束，稍后重试；也可手动停止' % pid, flush=True)


def auto_cleanup_loop(stop_event):
    try:
        while not stop_event.is_set():
            try:
                cleanup_strays_once()
            except Exception as exc:  # 不让一次访问失败永久停掉后台清理
                print('auto-cleanup: 核验暂未完成: %s' % exc, flush=True)
            if stop_event.wait(3.0):
                break
    finally:
        with _stray_cleanup_lock:
            for pid in list(_stray_candidates):
                _forget_stray(pid)


def cleanup_stale_pid():
    """run.pid 指向的进程已经死了/不是引擎 → 清掉，免得界面误判成"正在运行" """
    p = run_pid()
    if p and alive(p) and _is_attach_process(_process_cmdline(p)):
        return False
    if p and not engine_alive():
        try:
            os.remove(PIDFILE)
        except OSError:
            pass
        return True
    return False


def maintenance_loop():
    """后台维护：日志超标就轮转（哪怕一直没人点开始，也不让它无限长）"""
    while True:
        time.sleep(300)
        try:
            if rotate_log():
                print("maintenance: 运行日志已轮转", flush=True)
        except Exception:  # noqa: BLE001
            pass


def config():
    try:
        with open(CONF, encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:  # noqa: BLE001
        return {}


def course_read_wait():
    """只读同一个节奏记录；控制台提早提示，引擎仍做最终检查。"""
    try:
        limit = round(float(config().get("scan_min_seconds") or 60))
        if not 0 < limit <= 2_147_483_647:
            limit = 60
    except (TypeError, ValueError, OverflowError, AttributeError):
        limit = 60
    try:
        with open(PACE_FILE, encoding="utf-8-sig") as f:
            stamp = json.load(f).get("lastScanAt")
        last = datetime.fromisoformat(stamp).timestamp()
    except (OSError, TypeError, ValueError, OverflowError, AttributeError):
        return 0
    return max(0, math.ceil(limit - (time.time() - last)))


def read_wait_message(seconds):
    return f"再次识别还需等 {seconds} 秒。"


def scan_page_key(page):
    if page.get("classroom_tabs") == 1 and page.get("target_id") and page.get("url"):
        return page["target_id"], urllib.parse.urldefrag(page["url"]).url
    return None


def start_course_issue(page):
    """确认已手动识别，且当前页面属于保存的课程。"""
    if page.get("classroom_tabs", 0) > 1:
        return "检测到多个课堂标签。请只保留要使用的课堂标签。"
    course_sections()
    with _course_lock:
        if not _course.get("identified"):
            return "还没有课程清单。请先点「重新识别」，等清单更新后再开始。"
        course_id, origin, sections = _course["courseid"], _course["origin"], _course["val"]
    parsed = urllib.parse.urlsplit(page.get("url") or "")
    current_origin = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, "", "", ""))
    ids = urllib.parse.parse_qs(parsed.query).get("id", [])
    if current_origin == origin and len(ids) == 1 and ids[0].isdigit():
        item_id = ids[0]
        if parsed.path.endswith("/course/view.php") and item_id == course_id:
            return ""
        if parsed.path.endswith("/course/section.php") and any(s.get("id") == item_id for s in sections):
            return ""
        activity = page.get("activity") or _activity_ref(page.get("url") or "")
        if activity and any(it.get("id") == item_id and it.get("type") == activity["mod"] and it.get("video") is True
                            for s in sections for it in s.get("items", [])):
            return ""
    return "当前页面和课程清单不一致。请回到已识别的课程，或点「重新识别」更新清单。"


def scan_handoff_for(page):
    """仅本控制台启动并成功保存的识别，可以直接交给下一次开始操作。"""
    key = scan_page_key(page)
    with _scan_lock:
        if key is None or key != _scan_handoff.get("page"):
            return ""
        token = _scan_handoff["token"]
    course_sections()  # 刷新同一个原子快照的识别标记和写入时间
    with _course_lock:
        age = time.time() - _course.get("handoff_saved_at", 0)
        if _course.get("handoff_token") == token and 0 <= age < 120:
            return token
    return ""


def debug_port():
    try:
        return int(config().get("edge_attach_port") or DEFAULT_DEBUG_PORT)
    except Exception:  # noqa: BLE001
        return DEFAULT_DEBUG_PORT


_cdp = {"t": 0.0, "v": None}
_edge_connection = {"state": "disconnected", "connected": False,
                    "message": "先正常打开 Edge，再点「接管 Edge」；不会新建浏览器配置"}
# build_opener 实测约 27ms/次；状态轮询每 3 秒要问 2~3 次 CDP，复用同一个 opener。
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def cdp_up(max_age=2.0, timeout=0.25):
    """调试 Edge 是否就绪(端口能访问).

    端口没在监听时连接可能被丢弃而不是拒绝，会等满 timeout；用 0.25s，
    失败结果缓存 5 秒，避免 /api/status 每 3 秒都阻塞 0.6 秒。
    """
    ttl = max_age if _cdp["v"] is not False else 5.0
    if _edge_connection.get("state") == "connecting":
        ttl = min(ttl, 0.3)
    force = max_age <= 0
    if not force and time.time() - _cdp["t"] < ttl and _cdp["v"] is not None:
        return _cdp["v"]
    try:
        connection = edge_attach.local_request(debug_port(), timeout=timeout)
        _edge_connection.clear()
        _edge_connection.update(connection)
        _cdp["v"] = bool(connection.get("connected"))
    except Exception:  # noqa: BLE001
        _cdp["v"] = False
        _edge_connection.update(state="disconnected", connected=False,
                                message="先打开日常 Edge 并允许调试连接，再点「接管 Edge」")
    _cdp["t"] = time.time()
    return _cdp["v"]


def drop_stop_flag():
    try:
        os.remove(STOPFLAG)
    except OSError:
        pass


_pages = {"t": 0.0, "v": None, "detail": None}

# 与 识别规则.ps1 的 $VideoTypes 保持同一套兜底白名单（图标判据仍然优先）。
VIDEO_PLUGINS = {
    "fsresource", "video", "vod", "videofile", "local_video",
    "hvp", "h5pactivity", "mediasite", "kaltura", "vimeo",
    "youtube", "panopto", "echo360", "mediacore", "ivideo",
}
STRONG_VIDEO_PLUGINS = VIDEO_PLUGINS - {"fsresource"}


def _moodle_url(url):
    try:
        parts = urllib.parse.urlsplit(url or "")
        return (parts.scheme in ('http', 'https') and not parts.username and
                (parts.hostname or '').lower() == 'moodle.scnu.edu.cn')
    except Exception:  # noqa: BLE001
        return False


def _activity_ref(url):
    """从 Moodle 活动 URL 里取 (插件名, 活动 id)。

    `/mod/<plugin>/view.php?id=123` 是**所有**活动共用的地址形态：
    视频、PDF、讨论区、作业都长这样。只按这个正则判断"已到视频页"
    会把资料页误认成视频页，用户一点开始就报错。
    """
    try:
        parts = urllib.parse.urlsplit(url or "")
        m = re.search(r"/mod/([^/]+)/view\.php$", parts.path or "", re.I)
        if not m:
            return None
        q = urllib.parse.parse_qs(parts.query or "")
        aid = (q.get("id") or [""])[0].strip()
        if not re.fullmatch(r'[0-9]+', aid):
            return None
        return {"mod": m.group(1).lower(), "id": aid}
    except Exception:  # noqa: BLE001
        return None


def _activity_item(aid):
    """在引擎写下的课程结构里查这个活动，返回带 video 结论的条目。"""
    if not aid:
        return None
    try:
        for sec in course_sections():
            for it in (sec.get("items") or []):
                if str(it.get("id") or "") == str(aid):
                    return it
    except Exception:  # noqa: BLE001
        return None
    return None


def cdp_page_info(max_age=0.5, timeout=0.6):
    """只读枚举已接管 Edge 的课堂标签，返回 {state, title, url, activity, known}。

    state:
      login     还在 Moodle 登录页
      course    已登录，停在课程页（/course/view.php 或 section）
      moodle    已登录，但在首页/个人页等非课程页
      activity  打开了活动页，但**不是视频**（资料/讨论/作业等）
      unverified 活动页可能是视频，但课程结构里没有它的结论（需要重新识别）
      video     已确认打开视频活动（课程结构里的 video=true）
      other     Edge 有页面，但不是砺儒云课堂
      none      没开 Edge 或读不到
    """
    if time.time() - _pages["t"] < max_age and _pages["detail"] is not None:
        return _pages["detail"]
    detail = {"state": "none", "title": "", "url": "", "activity": None, "known": False}
    if cdp_up(max_age=0 if max_age <= 0 else 2.0, timeout=min(timeout, 0.25)):
        try:
            raw = _OPENER.open("http://127.0.0.1:%d/json/list" % debug_port(),
                               timeout=timeout).read()
            pages = [p for p in json.loads(raw.decode("utf-8", "replace"))
                     if p.get("type") == "page"]
            # 只有砺儒云课堂的页面参与判断；用户自己的其它标签页不背锅。
            moodle = [p for p in pages if _moodle_url(p.get("url") or "")]
            if len(moodle) > 1:
                _edge_connection['message'] = '检测到多个课堂标签，请只保留一个课堂标签；引擎连接时才会绑定'
            video_hit = activity_hit = unverified_hit = None
            login_hit = course_hit = moodle_hit = None
            # 一次建索引，避免标签数 × 课程活动数的重复遍历/读取。
            activity_index = {str(it.get('id') or ''): it
                              for sec in course_sections() for it in sec.get('items', [])}
            for p in moodle:
                url = p.get("url") or ""
                if "/login/" in url:
                    login_hit = login_hit or p
                    continue
                act = _activity_ref(url)
                if act:
                    known = activity_index.get(act["id"])
                    if known and known.get('type') and known['type'] != act['mod']:
                        known = None
                    is_video = None
                    if known is not None:
                        is_video = known.get("video")
                    if known and known.get("kind") == "unknown":
                        unverified_hit = unverified_hit or {"page": p, "act": act, "known": known}
                    elif is_video is True or (is_video is None and act["mod"] in STRONG_VIDEO_PLUGINS):
                        video_hit = video_hit or {"page": p, "act": act, "known": known}
                    elif is_video is None and act["mod"] in VIDEO_PLUGINS:
                        # fsresource 这类容器插件：结构里没结论时不能直接当视频，
                        # 也不当资料；提示用户先「重新识别」生成结构。
                        unverified_hit = unverified_hit or {"page": p, "act": act, "known": known}
                    else:
                        # 结构里明确是资料，或明确不在视频插件白名单：不能当视频页。
                        activity_hit = activity_hit or {"page": p, "act": act, "known": known}
                    continue
                if re.search(r"/course/(view|section)\.php(?:[?#]|$)", url):
                    course_hit = course_hit or p
                else:
                    moodle_hit = moodle_hit or p
            pick = None
            state = "none"
            if video_hit:
                pick, state = video_hit, "video"
            elif course_hit:
                pick, state = course_hit, "course"
            elif login_hit:
                pick, state = login_hit, "login"
            elif unverified_hit:
                pick, state = unverified_hit, "unverified"
            elif activity_hit:
                pick, state = activity_hit, "activity"
            elif moodle_hit:
                pick, state = moodle_hit, "moodle"
            elif pages:
                pick, state = pages[0], "other"
            if pick:
                page = pick.get("page") if isinstance(pick, dict) and "page" in pick else pick
                act = pick.get("act") if isinstance(pick, dict) else None
                known = pick.get("known") if isinstance(pick, dict) else None
                detail = {"state": state,
                          "title": (page.get("title") or "").strip(),
                          "url": page.get("url") or "",
                          "target_id": page.get("id") or "",
                          "activity": act,
                          "known": known if isinstance(known, dict) else None,
                          "classroom_tabs": len(moodle)}
        except Exception:  # noqa: BLE001
            detail = {"state": "none", "title": "", "url": "", "activity": None, "known": False}
    _pages["detail"] = detail
    _pages["v"] = detail["state"]
    _pages["t"] = time.time()
    return detail


def cdp_page_state(max_age=2.0, timeout=0.6):
    """兼容旧调用：只返回页面状态字符串。"""
    return cdp_page_info(max_age, timeout)["state"]


_pagetitle = {"t": 0.0, "v": ""}


def cdp_page_title(max_age=2.0, timeout=0.6):
    """已接管 Edge 当前视频页的标题，如 "第11讲-表单元素 | 砺儒云课堂"。

    用途：引擎有一类路径不写 `--- 第 N/M 讲 ---` 表头，此时"正在刷哪一讲"只能
    从页面标题反推（2026-09-16 实测：整轮 15 分钟的进度日志没有任何表头，
    清单与进度面板因此全空）。取不到就返回空串，调用方自行兜底。
    """
    if time.time() - _pagetitle["t"] < max_age:
        return _pagetitle["v"]
    title = ""
    try:
        d = cdp_page_info(max_age, timeout)
        if d.get("state") in ("video", "activity"):
            title = (d.get("title") or "").strip()
    except Exception:  # noqa: BLE001
        title = ""
    _pagetitle["v"], _pagetitle["t"] = title, time.time()
    return title


def clean_page_title(title):
    """去掉标题尾巴的 " | 砺儒云课堂" 之类站点名，只留讲次名。"""
    t = (title or "").strip()
    for sep in ("|", "－", " - "):
        if sep in t:
            t = t.split(sep)[0].strip()
    return t


def course_lookup():
    return core.map_course(course_sections(), _course.get("current") or "")


def spawn_ps(switches=(), limit=0, scope='current', chapter=''):
    """后台起 PowerShell 跑引擎。

    注意: **不能用 DETACHED_PROCESS** —— PowerShell 5.1 没有控制台时不会执行
    （实测: DETACHED 组合都失败, 只用 CREATE_NO_WINDOW 才正常）。这里用
    CREATE_NO_WINDOW + CREATE_NEW_PROCESS_GROUP: 不弹黑框, 且能脱离父进程存活。
    """
    args = [ps_exe(), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", PS1]
    args.extend(switches)
    if limit and int(limit) > 0:
        args.extend(["-Limit", str(int(limit))])
    # engine 的 param 默认是 forward；current/chapter/all 都必须显式传，
    # 否则前端选“只刷当前章”会被静默当成 forward。
    if scope in ("current", "chapter", "all"):
        args.extend(["-Scope", scope])
        if chapter:
            args.extend(["-Chapter", chapter])
    with _scan_lock:
        proc = subprocess.Popen(args, cwd=HERE, close_fds=True,
                                creationflags=CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _owned_engines[int(proc.pid)] = {'proc': proc, 'launcher': '-AttachEdge' in switches}
    _engines["t"] = 0.0
    # 只约束本项目引擎；接管服务和用户 Edge 独立于引擎生命周期。
    if "-AttachEdge" not in [str(x) for x in switches]:
        _bind_job(proc)
    return proc


def start_run(limit=0, mode='forward', chapter=''):
    if engine_alive():
        return False, "已经在运行中"
    if scan_alive():
        return False, "正在重新识别，等它结束再开始"
    if _owned_engine_pids(include_launchers=False):
        return False, "脚本正在启动，请稍等"
    strays = stray_engines()
    if strays:
        return False, "正在确认并自动清理残留脚本，请稍等；也可手动点「停止」"
    if not os.path.exists(PS1):
        return False, "找不到 auto_course.ps1"
    if not cdp_up():
        return False, "尚未接管 Edge，请先点「接管 Edge」并在浏览器中确认授权"
    if mode == 'chapter' and not chapter:
        return False, "请先在「刷课范围」里选一个章节"
    # 页面在两次轮询之间可能被切走：开刷前强制重读一次，别让引擎附着到登录页/资料页。
    pinfo = cdp_page_info(max_age=0)
    pstate = pinfo.get("state")
    if mode in ("forward", "current") and pstate != "video":
        return False, "当前浏览器标签页不是视频页，请先在课堂标签中点开一讲视频，再开始"
    if mode in ("all", "chapter") and pstate not in ("video", "course"):
        return False, "先打开课程页或一讲视频，再开始"
    issue = start_course_issue(pinfo)
    if issue:
        return False, issue
    handoff = scan_handoff_for(pinfo)
    housekeeping_async()          # 后台做日志轮转
    drop_stop_flag()
    if handoff:
        proc = spawn_ps(["-ScanHandoff", handoff], limit=limit, scope=mode, chapter=chapter)
        with _scan_lock:
            _scan_handoff.clear()
    else:
        proc = spawn_ps(limit=limit, scope=mode, chapter=chapter)
    for _ in range(80):           # 最多 8 秒；不再先无条件等待半秒
        if engine_alive():
            # 这里不能再清 stop.flag：用户可能在启动的 8 秒窗口里刚点了停止，
            # 清掉就等于吞掉停止请求。引擎自己会在等待/播放循环里处理它。
            return True, "已开始刷课"
        if proc is not None and proc.poll() is not None:
            break
        time.sleep(0.1)
    return False, "脚本没能起来，可双击程序文件夹里的「2-开始刷课.bat」查看报错"


# ---------------- 关标签页 = 停脚本（信标 + 宽限取消） ----------------
# 用户主路径：大部分人不会走「停止 → 关闭控制台 → 关标签页」，而是直接关标签页。
# 页面 pagehide 时 sendBeacon('/api/bye')；这里进入宽限期，期内**任何一次轮询恢复**
# 都会自动取消（所以刷新/重开页面零误杀）；宽限走完才停引擎（走 stop_run，
# 引擎"保存进度并退出"）。配置 close_tab_stops_script=false 可关掉整个行为。
BYE_GRACE = 10.0                     # 默认宽限秒数（可被 配置.json 的 close_tab_grace_seconds 覆盖）
_bye_lock = threading.Lock()
_bye_state = {"at": 0.0}             # 最近一次告别的 monotonic 时刻；0 = 没有挂起的告别


# ---------------- 重新识别（把"刷新权"交给用户） ----------------
# 控制台显示的「还剩几讲」来自引擎**上次运行**写下的快照，可能是几小时前的：
# 用户自己在平台网页上看完一讲、老师新加了资源，界面都不会知道。
# 与其让控制台定时偷偷去核对（那会动用户的浏览器页面、还可能和刷课撞车），
# 不如给用户一个按钮：想刷新就点一下，明确、可控。
def start_scan():
    """起一次"只识别不播放"的引擎：重读课程结构 + 实时核对每一讲的完成情况。"""
    if engine_alive():
        return False, "已经有一个脚本在跑，等它结束再点「重新识别」"
    if scan_alive():
        return False, "正在重新识别，等它结束再点"
    if _owned_engine_pids(include_launchers=False):
        return False, "脚本正在启动，请稍等"
    if stray_engines():
        return False, "正在确认并自动清理残留脚本，请稍等；也可手动点「停止」"
    if not os.path.exists(PS1):
        return False, "找不到 auto_course.ps1"
    wait = course_read_wait()
    if wait:
        return False, read_wait_message(wait)
    if not cdp_up():
        return False, "尚未接管 Edge，请先点「接管 Edge」并在浏览器标签页中打开课程"
    pinfo = cdp_page_info(max_age=0)
    if pinfo.get("state") not in ("video", "course", "activity", "unverified"):
        return False, "请先在课堂标签中打开课程页或一讲视频，再点「重新识别」"
    drop_stop_flag()
    # 识别必须覆盖整门课：-ScanOnly 默认 scope=current，会把“待刷”限制在当前章，
    # 课程页甚至没有当前讲可用。这里显式 all，课程页/其它章也能正确核对。
    with _scan_lock:
        page_key = scan_page_key(pinfo)
        token = uuid.uuid4().hex if page_key else ""
        switches = ["-ScanOnly"]
        if token:
            switches.extend(["-ScanHandoff", token])
        proc = spawn_ps(switches, scope="all")
        _scan_handoff.update(token=token, page=page_key)
        _active_scan.update(pid=int(proc.pid), proc=proc)
    # 不在 HTTP 请求里等引擎写完 run.pid：那会把前端 busy 锁住 8 秒，
    # 用户刚点完识别就改不了范围。启动确认交给 /api/status 的 scan_proc。
    return True, "正在重新核对每一讲的完成情况…"


def bye_grace():
    try:
        v = float(config().get("close_tab_grace_seconds") or BYE_GRACE)
        return max(3.0, v)           # 下限 3 秒：刷新后的首轮轮询要来得及取消
    except Exception:  # noqa: BLE001
        return BYE_GRACE


def arm_bye():
    if not config().get("close_tab_stops_script", True):
        return
    with _bye_lock:
        _bye_state["at"] = time.monotonic()
    threading.Thread(target=_bye_watch, args=(time.monotonic(),), daemon=True).start()


def cancel_bye():
    with _bye_lock:
        _bye_state["at"] = 0.0


def _bye_watch(t0):
    """宽限看门狗。挂起 → 期内被取消就静默退出；走完宽限就停引擎（只停引擎，
    控制台进程保留 —— 重新打开页面即用，彻底退出仍走「关闭控制台」）。"""
    grace = bye_grace()
    deadline = t0 + grace
    while time.monotonic() < deadline:
        time.sleep(0.5)
        with _bye_lock:
            at = _bye_state["at"]
        if not at:
            return                                   # 已取消
        if time.monotonic() - at >= grace:
            break                                    # 距最后一次告别已满宽限
        deadline = at + grace                        # 期间又告别过一次 → 顺延
    with _bye_lock:
        _bye_state["at"] = 0.0
    msg = ""
    for _ in range(3):                               # 停干净为止（防和启动流程赛跑）
        try:
            _, msg = stop_run()
        except Exception as e:  # noqa: BLE001
            msg = repr(e)
        if not engine_alive():
            break
        time.sleep(1.0)
    print("bye: 页面已关闭，脚本已自动停止（%s）。重新打开 127.0.0.1:8765 可继续使用。"
          % (msg or "无运行中的脚本"), flush=True)


def attach_edge():
    with _run_lock:
        if engine_alive() or scan_alive():
            return False, "请先停止任务，再接管或切换课堂标签"
        try:
            data_dir = None
            if '--edge-data-dir' in sys.argv:
                pos = sys.argv.index('--edge-data-dir')
                if pos + 1 >= len(sys.argv) or sys.argv[pos + 1].startswith('--'):
                    raise edge_attach.AttachError('--edge-data-dir 缺少已有 Edge 资料目录，请补全参数后重启控制台')
                data_dir = sys.argv[pos + 1]
            edge_attach.ensure_service(debug_port(), data_dir, parent_pid=os.getpid())
            state = edge_attach.local_request(debug_port(), 'connect', timeout=2)
            _edge_connection.clear()
            _edge_connection.update(state)
            _cdp.update(t=0.0, v=None)
            _pages.update(t=0.0, v=None, detail=None)
            return state['state'] != 'error', state['message']
        except Exception as exc:
            message = str(exc) if isinstance(exc, edge_attach.AttachError) else '接管未完成，请检查 Edge 的调试授权后重试'
            _edge_connection.update(state='error', connected=False, message=message)
            return False, message


def stop_run():
    """先发停止信号，15 秒后仅通过已核验并持有的进程句柄强制结束。"""
    with _stop_lock:
        pid = run_pid()
        procs = engine_processes(max_age=0, force=True)
        candidates = {e['pid'] for e in procs}
        if pid and engine_alive():
            candidates.add(pid)
        pinned, unresolved = [], []
        try:
            for target in sorted(candidates):
                proc = _pin_engine(target)
                if proc:
                    pinned.append(proc)
                elif alive(target) and is_engine_cmd(_process_cmdline(target)):
                    unresolved.append(target)
            launchers = [p for p in pinned if p['launcher']]
            targets = [p for p in pinned if not p['launcher']]
            # -AttachEdge is an authorization helper, not a playback task.
            # A stop request must not kill it while Edge is asking for consent.
            _engines['t'] = 0.0
            if targets or unresolved:
                try:
                    with open(STOPFLAG, 'w', encoding='ascii') as f:
                        f.write('stop')
                except OSError as e:
                    return False, '无法写入停止标记: %s' % e
                for _ in range(30):
                    if not any(_pinned_running(p) for p in targets) and not unresolved:
                        break
                    time.sleep(0.5)
                    unresolved = [p for p in unresolved if alive(p) and is_engine_cmd(_process_cmdline(p))]
            forced = []
            for proc in targets:
                if _pinned_running(proc) and _terminate_pinned(proc):
                    forced.append(proc['pid'])
            if forced:
                time.sleep(0.5)
            survivors = [p['pid'] for p in targets if _pinned_running(p)] + unresolved
            if survivors:
                return False, ('还有 %d 个进程未结束或身份无法核验（PID %s），已保留运行记录，请用 停止刷课.bat 再试'
                               % (len(survivors), ', '.join(map(str, survivors))))
            # 独立 bat 可能在等待期间启动新实例；不要删除它刚写的 PID/停止信号。
            current_pid = run_pid()
            if os.path.exists(PIDFILE) and current_pid is None:
                return False, '身份无法核验，已保留运行记录，请检查 run.pid'
            if current_pid is not None and current_pid != pid:
                return False, '原进程已结束，但运行记录已变化；请重新检查当前状态'
            if launchers and pid in {p['pid'] for p in launchers}:
                return False, '接管进程仍在等待授权，请在 Edge 中确认；已保留接管记录'
            if current_pid and alive(current_pid) and not is_engine_cmd(_process_cmdline(current_pid)):
                return False, '身份无法核验，已保留运行记录；未结束身份不符的进程'
            drop_stop_flag()
            try:
                os.remove(PIDFILE)
            except OSError:
                pass
            if forced:
                return True, '脚本未响应停止信号，已强制结束（PID %s）' % ', '.join(map(str, forced))
            if targets or candidates - {p['pid'] for p in launchers}:
                return True, '已停止'
            return False, '当前没有在运行'
        finally:
            for proc in pinned:
                k32.CloseHandle(proc['handle'])
            _engines['t'] = 0.0


# 对外动作统一串行化。放在函数定义之后绑定，do_POST / 看门狗拿到的都是包装版。
start_run = _serialized(start_run)
start_scan = _serialized(start_scan)
attach_edge = _serialized(attach_edge)
stop_run = _serialized(stop_run)


# ---------------- 日志解析 ----------------
# ---------------- 存储控制：日志轮转 / 缓存清理 ----------------
LOG_MAX_BYTES = 1024 * 1024          # 运行日志超过 1MB 就轮转, 只保留一份归档
LOG_ARCHIVE = os.path.join(HERE, "运行日志_归档.txt")
_trim_lock = threading.RLock()      # rotate_log 可能从已持锁的 housekeeping 里再进来


def rotate_log():
    """日志只保留最近一段, 避免无限膨胀。

    引擎正在写日志时绝不轮转：否则这一轮的清单/进度会被清空，历史也被挪进归档。
    """
    if engine_alive():
        return False
    with _trim_lock:
        try:
            if os.path.getsize(LOGFILE) <= LOG_MAX_BYTES:
                return False
            backup = LOG_ARCHIVE + ".old"
            if os.path.exists(LOG_ARCHIVE):
                os.replace(LOG_ARCHIVE, backup)
            try:
                os.replace(LOGFILE, LOG_ARCHIVE)
            except OSError:
                if os.path.exists(backup):
                    os.replace(backup, LOG_ARCHIVE)
                return False
            try:
                if os.path.exists(backup):
                    os.remove(backup)
            except OSError:
                pass
            return True
        except OSError:
            return False


def housekeeping_async():
    """只轮转本工具日志，不碰任何浏览器资料。"""
    def job():
        if rotate_log():
            print('运行日志已轮转（旧的存为运行日志_归档.txt）', flush=True)
    threading.Thread(target=job, daemon=True).start()


# ---------------- 日志 -> 人话 ----------------
_parse_lock = threading.Lock()
_log_reader = IncrementalLogReader()


def parse_log():
    # Read and reduce under one lock: concurrent HTTP polls cannot commit an old
    # file revision after a new one. Returned objects never alias the cache.
    with _parse_lock:
        return _log_reader.read(LOGFILE)


def _parse_log_impl():
    """Compatibility/reference path for offline tests; production is incremental."""
    return core.parse_lines(read_text(LOGFILE, limit=5000))


# ---------------- 课程结构（引擎实时识别结果的读取缓存） ----------------
_course = {"key": None, "val": [], "t": "", "current": ""}
_course_lock = threading.Lock()


def course_sections():
    """引擎写的课程结构 → 章节视图；按文件身份和时间戳缓存，返回隔离副本。

    done 是引擎实时核对页面后的结果：True=已完成 / False=还没完成 / None=还没核对过。
    """
    with _course_lock:
        # 从同一打开句柄取身份与内容；整段加锁，旧读者不能覆盖新快照。
        if _course.get('path') != COURSE_FILE:
            _course.update(key=None, val=[], t='', current='', courseid='', path=COURSE_FILE,
                           handoff_token='', handoff_saved_at=0, identified=False, origin='')
        try:
            with open(COURSE_FILE, 'rb') as f:
                st = os.fstat(f.fileno())
                key = (COURSE_FILE, st.st_dev, st.st_ino, st.st_mtime_ns, st.st_ctime_ns, st.st_size)
                if key == _course['key']:
                    return copy.deepcopy(_course['val'])
                raw = f.read()
                after = os.fstat(f.fileno())
                if (st.st_size, st.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                    return copy.deepcopy(_course['val'])
            d = json.loads(raw.decode('utf-8-sig'))
            secs = core.normalize_course(d)
            stamp, cur_id = str(d.get('updated') or ''), str(d.get('current') or '')
        except FileNotFoundError:
            _course.update(key=None, val=[], t='', current='', courseid='',
                           handoff_token='', handoff_saved_at=0, identified=False, origin='')
            return []
        except (OSError, ValueError, TypeError):
            # 分享冲突/半写只保留同一文件的上次有效数据，下次重试。
            return copy.deepcopy(_course['val'])
        _course["key"] = key
        _course["val"] = secs
        _course["t"] = stamp
        _course["current"] = cur_id
        _course['courseid'] = str(d.get('courseid') or '')
        _course['identified'] = d.get('identified') is True
        _course['origin'] = str(d.get('origin') or '')
        _course['handoff_token'] = str(d.get('scan_handoff') or '')
        _course['handoff_saved_at'] = st.st_mtime
        return copy.deepcopy(secs)


# 分类只在引擎里做（识别规则.ps1 的图标→文件→插件三级判据），控制台**不再自己判**。
# 旧版这里有一份 VIDEO_TYPES / NON_VIDEO_TYPES，和引擎那份各判一次、还互相不一致：
# 引擎把 tracked 的 resource 判成视频，控制台把 resource 判成非视频 —— 用户看到的
# "课件与参考资料 还剩 1 讲"就是两套表打架的结果。现在只有一个来源：引擎写进
# 课程结构.json 的 video 字段。
#
# 兼容老快照（没有 video 字段）：按"未知"处理 —— 保留、按可能是视频统计，绝不再猜类型。
_looks_video = core._looks_video
_video_sections = core._video_sections
_is_counted = core._is_counted


def build_chapters(cur_name="", cur_id=""):
    return core.map_chapters(course_sections(), cur_name, cur_id)


def _different_course(page_info, by_id):
    """只在有明确身份不符证据时丢弃旧课程的展示，运行中的日志另保留。"""
    cached_id = _course.get('courseid')
    if not cached_id:
        return False
    try:
        u = urllib.parse.urlsplit(page_info.get('url') or '')
        if re.search(r'/course/view\.php$', u.path):
            cid = (urllib.parse.parse_qs(u.query).get('id') or [''])[0]
            return bool(cid and cid != cached_id)
        if re.search(r'/course/section\.php$', u.path):
            sid = (urllib.parse.parse_qs(u.query).get('id') or [''])[0]
            secs = _course.get('val') or []
            # 旧快照没有 section ID 时不猜；完整数字 ID 集合才支持此判断。
            ids = {str(s.get('id') or '') for s in secs}
            return bool(sid.isdigit() and ids and all(x.isdigit() for x in ids) and sid not in ids)
        act = page_info.get('activity') or {}
        return bool(act.get('id') and act['id'] not in by_id)
    except (ValueError, TypeError):
        return False


def build_status():
    """只返回对使用者有用的信息: 在不在正常跑 / 刷到哪 / 有没有要处理的事."""
    info = parse_log()
    running = engine_alive()
    scanning = scan_alive()
    cdp = cdp_up()
    page_info = cdp_page_info() if cdp else {"state": "none", "title": "", "activity": None}
    page = page_info.get("state", "none")
    page_title = clean_page_title(page_info.get("title", "")) if page in ("video", "activity", "unverified") else ""
    done = len([1 for it in info["items"] if it["status"] == "已完成"])
    if not running:
        # 引擎被强杀/控制台退出时，日志可能没有收尾汇总；不能让清单永久停在“播放中”。
        for it in info["items"]:
            if it.get("status") in ("播放中", "进行中"):
                it["status"] = "中断"
    cur, p = info["current"] or {}, info["progress"] or {}
    # 节奏提示由实时记录产生；历史拒绝日志仍留在动态列表。
    local_guard = ("发生错误：课程读取间隔不足 ", "课程读取间隔检查失败，本次不请求网站")
    warn = next((row for row in reversed(info["warns"])
                 if not row["text"].startswith(local_guard)), None)
    strays = stray_engines()
    by_id, by_name, cur_id = course_lookup()

    # 本轮各讲的课程编号(第N讲)齐全时, 算出"本周第 k/n 讲"。
    # 注意：这个函数必须**在讲次补齐之后再调一次** —— 补齐走的是课程结构/页面标题，
    # 那时才第一次拿到 lec_no 和 items。
    def add_week(c):
        nums = sorted(it["lec_no"] for it in info["items"] if it.get("lec_no"))
        if c.get("lec_no") and c["lec_no"] in nums and len(nums) > 1:
            return dict(c, week={"k": nums.index(c["lec_no"]) + 1,
                                 "n": info["planned"] or len(nums)})
        return c

    # ---- 讲次补齐（本 bug 的核心修复）------------------------------------
    # 引擎有一类路径不写 `--- 第 N/M 讲 ---` 表头（直接接管你已打开的视频页），
    # 于是 info["current"] 是空的、进度也挂靠不上。以前的结果是整块界面全空。
    # 按可靠度依次补：① 已接管 Edge **当前页面标题** —— 它反映的是"此刻真在播哪一讲"
    #                ② 课程结构.json 的 current 活动 id —— 那只是"本轮起点"，
    #                   跑起来之后就不再更新，所以排在标题后面
    if running and not cur:
        src = ""
        hit, nm = None, ""
        if cdp:
            nm = clean_page_title(cdp_page_title())
            # 只有标题确实在本课程结构里，才拿它当“当前讲”。
            # 已接管 Edge 里同时开着别的课/别的视频页时，不能张冠李戴。
            page_id = (page_info.get('activity') or {}).get('id', '')
            if page_id in by_id or (nm and by_name.get(nm)):
                hit, src = by_id.get(page_id) or by_name[nm], "页面标题"
                nm = hit['title']
            else:
                nm = ""
        if not nm and cur_id and cur_id in by_id:
            hit, nm, src = by_id[cur_id], by_id[cur_id]["title"], "课程结构"
        if nm:
            cur = {"index": 0, "total": info["planned"] or 0, "name": nm}
            if hit:
                cur['id'] = hit.get('id', '')
                cur["chapter"] = hit["section"]
                cur["chapter_short"] = short_chapter(hit["section"])
            lno = lecture_no(nm)
            if lno:
                cur["lec_no"] = lno
            cur["_inferred"] = src        # 告诉前端：讲次是推出来的，别硬报 N/M
        if not p and info.get("progress_unattached"):
            p = info["progress_unattached"]     # 挂靠不明的进度，这时候才有意义

    # 未运行但已接管 Edge 停在某个视频页：用页面标题给出“准备从哪一讲开始”，
    # 避免界面一直显示上一轮的旧讲名。
    if not running and page == "video" and cdp:
        nm = clean_page_title(cdp_page_title())
        hit = by_id.get((page_info.get('activity') or {}).get('id', '')) or (by_name.get(nm) if nm else None)
        if hit:
            nm = hit['title']
            cur = {"index": 0, "total": info["planned"] or 0, "name": nm,
                   "id": hit.get('id', ''),
                   "chapter": hit["section"], "chapter_short": short_chapter(hit["section"]),
                   "_inferred": "页面标题"}
            lno = lecture_no(nm)
            if lno:
                cur["lec_no"] = lno
            p = {}
        elif nm:
            # 标题不在本课程结构里：不要继续沿用上一门课的 cur，否则界面和引擎会错位。
            cur = {"index": 0, "total": 0, "name": nm,
                   "_inferred": "页面标题", "_unlisted": True}
            p = {}

    # 引擎刚起来、还没写「接管模式」/附着浏览器的那几秒：
    # 这时 items 恒为空，但**不能**据此补清单、更不能当成“正在刷课”。
    # 旧逻辑先补清单再判状态，补完之后 `not info["items"]` 永远为假，
    # 于是旧连接入口启动时被显示成「正在刷课」。
    boot_wait = bool(running and not info["items"] and not cur
                     and not info.get("edge_only") and not info.get("scan_only")
                     and not info.get("saw_attach"))

    # 清单为空时，用课程结构补出"本轮要刷哪几讲"——
    # 引擎没写「本次将处理/计划 N.」时清单是空的，但结构文件里每个活动都带 done，
    # 而且 current 所在章节的未完成项就是本轮范围（默认 Scope=forward 从当前讲往后）。
    # 只有“正在开刷但计划行还没到”时才补本轮清单；重新识别完成后不补逐讲行，
    # 前端显示核对回执/“请选择讲次”，等按下开始后由引擎计划行生成清单。
    if running and not info["items"] and not boot_wait             and not info.get("edge_only") and not info.get("scan_only"):
        secs = course_sections()
        target = None
        if cur.get('id'):
            target = next((sec for sec in secs if any(i['id'] == cur['id'] for i in sec['items'])), None)
        if not target and cur.get("name") and cur['name'] in by_name:
            for sec in secs:
                if any(i["title"] == cur["name"] for i in sec["items"]):
                    target = sec
                    break
        if not target and cur.get("chapter"):
            target = next((sec for sec in secs if sec["name"] == cur["chapter"]), None)
        if not target and cur_id and cur_id in by_id:
            sec_name = by_id[cur_id].get("section")
            target = next((sec for sec in secs if sec["name"] == sec_name), None)
        if target:
            pending = [i for i in target["items"]
                       if i.get("done") is not True and _is_counted(i)]
            built = []
            for k, i in enumerate(pending):
                row = {"index": k + 1, "id": i.get('id', ''), "name": i["title"], "status": "等待中", "pct": 0,
                       "chapter": target["name"],
                       "chapter_short": short_chapter(target["name"])}
                lno = lecture_no(i["title"])
                if lno:
                    row["lec_no"] = lno
                built.append(row)
            info["items"] = built
            if built and not info["planned"]:
                info["planned"] = len(built)
            done = len([1 for it in built if it["status"] == "已完成"])

    # 日志里的计划行没有章节；用课程结构按标题反查补齐，圆盘/清单才能按真实章节分组。
    for it in info["items"]:
        if not it.get("chapter"):
            hit = by_id.get(it.get('id')) or by_name.get(it.get("name") or "")
            if hit:
                it["chapter"] = hit["section"]
                it["chapter_short"] = short_chapter(hit["section"])

    # 没读到讲次表头时，进度挂到清单里"进行中"的那条上（让清单行也会动）
    if running and p and cur.get("name"):
        for it in info["items"]:
            same = (it.get('id') == cur['id'] if cur.get('id') else
                    it.get('index') == cur.get('index') and it['name'] == cur['name'])
            if same and it["status"] == "等待中":
                it.update(pct=p.get("pct", 0), status="播放中")
                if p.get("dur"):
                    it["dur"] = p["dur"]

    # 讲次补齐/清单补齐都做完之后，最后一遍算"本周第 k/n 讲"（这才有完整数据）
    cur = add_week(cur)

    # 每章完成度（引擎跑过识别后才有）
    chapters = build_chapters(cur.get("name") or "", cur.get("id") or "")
    different_course = not running and not scanning and _different_course(page_info, by_id)
    if different_course:
        # 上门课的扫描回执与章节不能挂到新课上；下一次识别后自然恢复。
        info.update(items=[], planned=0, scan_done=False, scan_only=False, scan_at='',
                    scan_for='', scan_scope='', run_started=None, run_ended=None)
        cur, p, chapters, done, warn = {}, {}, [], 0, None

    state, state_text, note, hint, warn = core.select_state(
        info, running, scanning, cdp, page, cur, p, warn, boot_wait, strays,
        time.strftime("%H:%M"))
    if not running and not scanning and not strays:
        if _edge_connection.get("state") == "connecting":
            state, state_text = "edge", "等待接管授权"
            note = "请在 Edge 中确认调试连接"
            hint = _edge_connection.get("message", "")
        elif not cdp or page == "none":
            hint = _edge_connection.get("message", "")
        elif page_info.get('classroom_tabs', 0) > 1:
            note = hint = _edge_connection.get('message', '')
    if not running and not scanning and strays:
        cleanup_states = _auto_cleanup_state([e['pid'] for e in strays])
        if 'failed' in cleanup_states.values():
            note = '残留脚本暂未清理成功，稍后会重试'
            hint = '可点「停止」手动处理；身份无法核验时不会自动结束进程'
            warn = {'time': time.strftime('%H:%M'), 'level': '警告', 'text': note}
    read_wait = course_read_wait()
    start_issue = ''
    can_start_from_scan = False
    if not running and not scanning and not strays and cdp and page in ("video", "course"):
        start_issue = start_course_issue(page_info)
        can_start_from_scan = not start_issue
        if start_issue and state in ("ready", "setup"):
            state, state_text = "setup", "等待识别"
            note = hint = start_issue
    # 本轮用时 / 预计剩余：都是清单里没有的聚合信息，避免和「讲次」列表重复。
    # 时长来自引擎本遍播放时记录的 duration；没播过的讲按已知均值估。
    elapsed, eta = core.estimate_times(info, running, done, time.time())

    return {
        "state": state, "state_text": state_text, "note": note, "hint": hint,
        "alive": running, "pid": run_pid(), "scan_proc": scanning,
        "warn": warn, "cdp_up": cdp, "edge_connection": dict(_edge_connection),
        "scanned": bool(info.get("scan_done")),
        "scan_only": bool(info.get("scan_only")),
        "scan_at": info.get("scan_at", ""),
        "scan_for": (info.get("scan_for") if info.get("scan_for") in by_name else ""),
        "scan_scope": info.get("scan_scope", ""),
        "page": page, "page_title": page_title, "ver": BUILD_TAG, "caps": list(CAPS),
        "course_time": '' if different_course else _course.get("t", ""),
        "read_wait_seconds": read_wait,
        "can_start_from_scan": can_start_from_scan, "start_course_issue": start_issue,
        "elapsed_seconds": elapsed, "eta_seconds": eta, "run_ended": info.get("run_ended"),
        "planned": info["planned"], "current": cur, "progress": p,
        "items": info["items"], "done_count": done, "feed": info["feed"],
        "chapters": chapters, "strays": strays,
        "unverified_count": 0 if different_course else sum(1 for s in course_sections() for it in s["items"]
                                                           if it.get("kind") == "unknown"),
        "review_items": [] if different_course else [
            {"id": it["id"], "name": it["title"], "chapter": sec["name"], "type": it.get("type", "")}
            for sec in course_sections() for it in sec["items"] if it.get("kind") == "unknown"],
        "time": time.strftime("%H:%M:%S"),
    }

def detach_edge():
    """兼容旧调用名：仅退出本机适配器，绝不关闭用户 Edge。"""
    try:
        edge_attach.local_request(debug_port(), 'disconnect', timeout=2)
    except Exception:
        pass
    _cdp.update(t=0.0, v=False)
    _edge_connection.update(state='disconnected', connected=False, message='已断开接管，Edge 保持打开')


def prepare_console_close():
    global _console_closing
    with _run_lock:
        if _console_closing:
            return True, '控制台正在关闭'
        try:
            ok, msg = stop_run()
        except Exception as exc:
            return False, '停止未完成，已保留控制台和运行记录：%s' % exc
        if not ok and msg != '当前没有在运行':
            return False, msg
        _console_closing = True
        return True, '引擎已停止，正在关闭控制台'


def shutdown_console(server, prepared=False):
    """界面上的「关闭控制台」：先优雅停刷课（含残留脚本），再断开接管，最后退服务。

    顺序很重要 —— 先把刷课停干净，最后才退出服务；否则就成了"先关控制台、
    刷课还在后台跑"的幽灵脚本（这正是用户最烦的那种残留）。
    """
    if not prepared:
        ok, msg = prepare_console_close()
        if not ok:
            print('close: ' + msg, flush=True)
            return False
    try:
        detach_edge()
    except Exception:  # noqa: BLE001
        pass
    try:
        server.shutdown()
        server.server_close()
    except Exception:  # noqa: BLE001
        pass


class Server(ThreadingHTTPServer):
    """Windows 下必须关掉 SO_REUSEADDR, 否则第二个实例能"抢"同一个端口,
    会出现两个进程都在 LISTENING、请求被旧代码那份接走的灵异现象。"""
    allow_reuse_address = False


class Handler(BaseHTTPRequestHandler):
    server_version = "LiruCourseConsole"
    timeout = 15                         # 慢连接不许无限占线程

    def log_message(self, *a):
        pass

    # ---- 本机接口的最小防线 ----
    # 只监听 127.0.0.1 并不能挡住恶意网页用简单请求打过来，也挡不住 DNS rebinding。
    # Host 只认本机；Origin 只认同源；POST body 另外限长。curl / bat 没有 Origin，放行。
    def _port(self):
        # 用实际监听端口（测试可能起在 8766），不要写死全局 PORT。
        try:
            return int(self.server.server_address[1])
        except Exception:  # noqa: BLE001
            return PORT

    def _host_ok(self):
        host = (self.headers.get("Host") or "").strip().lower()
        port = self._port()
        allowed = {"127.0.0.1:%d" % port, "localhost:%d" % port,
                   "127.0.0.1", "localhost"}
        return host in allowed

    def _origin_ok(self):
        origin = (self.headers.get("Origin") or "").strip().lower().rstrip("/")
        if not origin:
            return True
        port = self._port()
        return origin in ("http://127.0.0.1:%d" % port, "http://localhost:%d" % port)

    def _deny(self):
        return self._send(403, json.dumps({"ok": False, "msg": "forbidden"}, ensure_ascii=False))

    def _send(self, code, body, ctype="application/json; charset=utf-8", cache="no-store"):
        if getattr(self, "_responded", False):
            return
        self._responded = True
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass

    def do_GET(self):
        try:
            split = urllib.parse.urlsplit(self.path)
            path = split.path
            if not self._host_ok():
                return self._deny()
            cancel_bye()
            if path in ("/", "/index.html"):
                if not os.path.exists(PAGE_HTML):
                    return self._send(500, "缺少 ui/index.html", "text/plain; charset=utf-8")
                with open(PAGE_HTML, encoding="utf-8") as f:
                    return self._send(200, f.read(), "text/html; charset=utf-8")
            if path in ("/shared/poll.js", "/shared/interface.js", "/shared/interface.css"):
                fp = os.path.join(HERE, "ui", "shared", path.rsplit("/", 1)[1])
                if not os.path.exists(fp):
                    return self._send(404, "缺少控制台资源", "text/plain; charset=utf-8")
                with open(fp, "rb") as f:
                    return self._send(200, f.read(), "text/css; charset=utf-8" if path.endswith('.css') else "application/javascript; charset=utf-8")
            if path == "/api/status":
                return self._send(200, json.dumps(build_status(), ensure_ascii=False))
            return self._send(404, json.dumps({"ok": False, "msg": "not found"}))
        except Exception as e:  # noqa: BLE001
            return self._send(500, json.dumps({"ok": False, "msg": repr(e)}))

    def do_POST(self):
        try:
            split = urllib.parse.urlsplit(self.path)
            path = split.path
            if not self._host_ok() or not self._origin_ok():
                return self._deny()
            try:
                n = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                n = -1
            if n < 0 or n > 65536:
                return self._send(400, json.dumps({"ok": False, "msg": "请求体过大或长度无效"},
                                                  ensure_ascii=False))
            raw = self.rfile.read(n) if n else b""
            body = {}
            if raw:
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, ValueError):
                    return self._send(400, json.dumps({"ok": False, "msg": "请求体不是合法 JSON"},
                                                      ensure_ascii=False))
            if not isinstance(body, dict):
                return self._send(400, json.dumps({"ok": False, "msg": "请求体必须是对象"},
                                                  ensure_ascii=False))
            if path == "/api/start":
                # start 必须明确带合法 mode；空 body / 表单请求不能默认开刷。
                if not raw:
                    return self._send(400, json.dumps({"ok": False, "msg": "缺少刷课范围"},
                                                      ensure_ascii=False))
                mode = str(body.get("mode") or "")
                if mode not in ("forward", "current", "chapter", "all"):
                    return self._send(400, json.dumps({"ok": False, "msg": "刷课范围无效"},
                                                      ensure_ascii=False))
                try:
                    limit = int(body.get("limit") or 0)
                except (TypeError, ValueError):
                    limit = 0
                ok, msg = start_run(limit=limit,
                                    mode=mode, chapter=str(body.get("chapter") or ""))
            elif path == "/api/stop":
                ok, msg = stop_run()
            elif path == "/api/scan":
                ok, msg = start_scan()
            elif path == "/api/bye":
                # 页面 pagehide 发来的告别信标（sendBeacon，body 为空）
                arm_bye()
                ok, msg = True, "进入宽限，轮询恢复即取消"
            elif path == "/api/attach-edge":
                ok, msg = attach_edge()
            elif path == "/api/detach-edge":
                if engine_alive() or scan_alive():
                    ok, msg = False, "请先停止任务，再断开 Edge"
                else:
                    detach_edge()
                    ok, msg = True, "已断开接管，Edge 窗口保持打开"
            elif path == "/api/close-console":
                # The existing clients allow 25 seconds. Confirm stop before claiming
                # success, so their error paths can restore the page on failure.
                ok, msg = prepare_console_close()
                if not ok:
                    return self._send(409, json.dumps({"ok": False, "msg": msg}, ensure_ascii=False))
                try:
                    self._send(200, json.dumps({"ok": True, "msg": msg}, ensure_ascii=False))
                finally:
                    threading.Thread(target=shutdown_console, args=(self.server, True),
                                     daemon=True).start()
                return
            else:
                # 走到这里最常见的原因**不是**"前端发错了请求"，而是**后端进程还是旧版本**：
                # 页面是每次 GET / 从磁盘读的，刷新一下就是最新的；但后端是常驻进程，
                # 改了 webui.py 不重启它就一直跑旧代码 —— 于是新按钮请求的新接口
                # 在旧后端眼里就成了"不认识的操作"（用户实报过一次，只有 4 个字根本没法排查）。
                ok, msg = False, (
                    "控制台后端不认识这个操作（当前后端版本 %s）。"
                    "如果你刚更新过脚本，多半是后端进程还在跑旧代码："
                    "双击「关闭控制台.bat」结束它，再双击「打开控制台」重开，然后刷新页面"
                    % BUILD_TAG)
            return self._send(200, json.dumps({"ok": ok, "msg": msg}, ensure_ascii=False))
        except Exception as e:  # noqa: BLE001
            return self._send(500, json.dumps({"ok": False, "msg": repr(e)}))


def open_browser():
    """用默认浏览器打开控制台页面。"""
    if "--no-open" in sys.argv:
        return
    try:
        os.startfile("http://%s:%d/" % (HOST, PORT))
    except Exception:  # noqa: BLE001
        pass


def main():
    # ① **先抢端口，再写 pid。顺序反了就出大问题**（2026-09-17 实测踩到）：
    #    端口被占时新进程照样写了 pid → 覆盖掉"正在服务那个实例"的身份证 →
    #    新进程随即退出，于是 pid 文件指向一个**已经不存在的进程**，
    #    而真正在服务的老进程谁也找不到了 —— 关闭控制台.bat 杀不掉它，
    #    用户就会陷入"怎么重启都换不成新版"的死局（他连着遇到两次）。
    try:
        srv = Server((HOST, PORT), Handler)
    except OSError as e:
        # 端口被占 = 已经有一个控制台在服务。这里**只读它、绝不改 webui.pid**。
        try:
            with _OPENER.open("http://%s:%d/api/status" % (HOST, PORT), timeout=2) as r:
                alive = json.loads(r.read().decode("utf-8"))
            print("已经有一个控制台在跑（后端版本 %s）" % alive.get("ver"), flush=True)
            if alive.get("ver") != BUILD_TAG:
                print("⚠ 它跑的是**旧代码**（本次代码是 %s）。"
                      "双击 关闭控制台.bat 结束它，再双击本入口，才能换成新版。"
                      % (BUILD_TAG,), flush=True)
            open_browser()
        except Exception:  # noqa: BLE001
            # 端口被别的程序占着（不是我们的控制台）
            print("端口 %d 已被别的程序占用：%s" % (PORT, e), flush=True)
        return

    # ② 端口抢到了 —— 此刻自己才是真正的服务者，这才写 pid
    try:
        with open(WEB_PID_FILE, "w", encoding="ascii") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    _log_reader.begin_session(LOGFILE)
    print("刷课控制台已启动: http://%s:%d" % (HOST, PORT), flush=True)
    cleanup_stale_pid()                 # 清掉指向"已经死掉的脚本"的旧 run.pid
    strays = stray_engines()
    if strays:
        print("注意：发现 %d 个不受本控制台管理的刷课脚本（进程 %s），"
              "后台将持续核验，确认后自动清理"
              % (len(strays), ",".join(str(e["pid"]) for e in strays)), flush=True)
    threading.Timer(0.6, open_browser).start()
    threading.Thread(target=keep_awake_loop, daemon=True).start()
    threading.Thread(target=maintenance_loop, daemon=True).start()
    cleanup_stop = threading.Event()
    cleanup_thread = threading.Thread(target=auto_cleanup_loop, args=(cleanup_stop,), daemon=True)
    cleanup_thread.start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        cleanup_stop.set()
        cleanup_thread.join(timeout=2.0)
        detach_edge()
        try:
            os.remove(WEB_PID_FILE)
        except OSError:
            pass


if __name__ == "__main__":
    main()
