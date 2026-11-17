"""日志 IO 层：按字节偏移读取新增完整行，文件替换/截断时重新归约。"""
import copy
import os

from webui_core import LogState


class IncrementalLogReader:
    def __init__(self):
        self.history = None
        self.reset()

    def reset(self, path=None):
        self.path = path
        self.identity = None
        self.stamp = None
        self.offset = 0
        self.prefix = b''
        self.tail = b''
        self.pending = b''
        self.encoding = 'utf-8-sig'
        self.state = LogState()
        self.value = self.state.snapshot()
        self.bytes_read = 0
        self.lines_parsed = 0

    def begin_session(self, path):
        """Keep existing log entries as history, including a pending partial line."""
        self.history = None
        self.reset()
        self.read(path)
        if self.identity is not None:
            self.history = (self.path, self.identity, self.offset, self.prefix, self.tail)
            self.state.warns.clear()
            self.value = self.state.snapshot()

    def read(self, path):
        path = os.path.abspath(os.fspath(path))
        if path != self.path:
            self.reset(path)
        try:
            with open(path, 'rb') as stream:
                stat = os.fstat(stream.fileno())
                identity = (stat.st_dev, stat.st_ino)
                stamp = (stat.st_mtime_ns, stat.st_size, stat.st_ctime_ns)
                if identity == self.identity and stamp == self.stamp:
                    # Windows can preserve the timestamp across rapid writes.
                    # Verify bounded guards even for an apparently unchanged file.
                    prefix = stream.read(len(self.prefix))
                    stream.seek(self.offset - len(self.tail))
                    tail = stream.read(len(self.tail))
                    self.bytes_read += len(prefix) + len(tail)
                    if prefix == self.prefix and tail == self.tail:
                        return copy.deepcopy(self.value)
                reset = identity != self.identity or stat.st_size < self.offset
                # Same-size edits are not appends. A prefix and old EOF guard
                # also catch truncate-and-regrow between adjacent status polls.
                if not reset and self.offset:
                    if stat.st_size == self.offset:
                        reset = True
                    else:
                        prefix = stream.read(len(self.prefix))
                        stream.seek(self.offset - len(self.tail))
                        tail = stream.read(len(self.tail))
                        self.bytes_read += len(prefix) + len(tail)
                        reset = prefix != self.prefix or tail != self.tail
                if reset:
                    self.reset(path)
                stream.seek(self.offset)
                # Use the observed size, not an unbounded read racing a writer.
                chunk = stream.read(max(0, stat.st_size - self.offset))
                self.bytes_read += len(chunk)
                initial = self.offset == 0
                history_end = 0
                if self.history is not None:
                    old_path, old_identity, end, head, tail = self.history
                    if old_path == path:
                        if identity != old_identity or (initial and
                                (len(chunk) < end or not chunk.startswith(head) or
                                 chunk[end - len(tail):end] != tail)):
                            # Rotation or an in-place rewrite starts a different log.
                            self.history = None
                        else:
                            history_end = end
                if initial:
                    self.prefix = chunk[:128]
                elif len(self.prefix) < 128:
                    self.prefix = (self.prefix + chunk)[:128]
                self.tail = (self.tail + chunk)[-256:]
                data_start = self.offset - len(self.pending)
                self.offset += len(chunk)
                data = self.pending + chunk
                last = data.rfind(b'\n')
                complete, self.pending = (data[:last + 1], data[last + 1:]) if last >= 0 else (b'', data)
                if initial and complete:
                    try:
                        complete.decode('utf-8-sig')
                    except UnicodeDecodeError:
                        # Retain the old GBK log fallback; a partial UTF-8 line
                        # is held above and never influences encoding selection.
                        if complete.decode('utf-8-sig', errors='replace').count('\ufffd') > 8:
                            self.encoding = 'gbk'
                lines = complete.decode(self.encoding, errors='replace').splitlines()
                history_bytes = min(len(complete), max(0, history_end - data_start))
                history_lines = complete.count(b'\n', 0, history_bytes)
                if history_bytes and complete[history_bytes - 1] != 10:
                    history_lines += 1
                if initial:
                    history_lines = max(0, history_lines - max(0, len(lines) - 5000))
                    lines = lines[-5000:]
                self.lines_parsed += len(lines)
                if history_lines:
                    self.state.consume(lines[:history_lines], historical=True)
                self.state.consume(lines[history_lines:])
                self.value = self.state.snapshot()
                self.identity, self.stamp = identity, stamp
        except FileNotFoundError:
            self.reset(path)
        except OSError:
            # Sharing/access races must not wipe the last good snapshot or
            # advance the checkpoint. The next poll retries the same revision.
            pass
        return copy.deepcopy(self.value)
