import pytest
from gm_runtime import InstanceLock, RetrySchedule

def test_lock_prevents_duplicate_writer_and_releases(tmp_path):
    path=tmp_path/'observer.lock'
    with InstanceLock(path):
        with pytest.raises(RuntimeError):
            with InstanceLock(path): pass
    with InstanceLock(path): pass

def test_reconnect_delay_is_bounded_and_resets():
    retry=RetrySchedule()
    assert retry.ready(0)
    retry.failed(0)
    assert not retry.ready(1) and retry.ready(2)
    for _ in range(100): retry.failed(10)
    assert retry.next_at==70
    retry.reset()
    assert retry.failures==0 and retry.ready(0)
