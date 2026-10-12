"""Process lifetime lock and bounded retry policy for local analytics."""
import os
from pathlib import Path


class InstanceLock:
    """OS-owned lock: released even when a process crashes. No stale PID decisions."""
    def __init__(self, path):
        self.path, self.handle = Path(path), None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        handle = open(self.path, 'a+b')
        if handle.tell() == 0:
            handle.write(b'0'); handle.flush()
        handle.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            handle.close()
            raise RuntimeError('El observatorio ya tiene una instancia activa.') from exc
        self.handle = handle
        return self

    def __exit__(self, *args):
        if self.handle:
            self.handle.close()
            self.handle = None


class RetrySchedule:
    def __init__(self):
        self.failures, self.next_at = 0, 0.0

    def ready(self, now):
        return now >= self.next_at

    def failed(self, now):
        self.failures += 1
        self.next_at = now + min(60, 2 ** min(self.failures, 6))

    def reset(self):
        self.failures, self.next_at = 0, 0.0
