import json
from unittest.mock import patch

import pytest

from gm_market_service import atomic_json


def test_temporary_reader_lock_retries(tmp_path):
    target = tmp_path / "snapshot.json"
    with patch("gm_market_service.os.replace", side_effect=[PermissionError(), None]) as replace:
        with patch("gm_market_service.time.sleep") as sleep:
            atomic_json(target, {"cycle": 1})
    assert replace.call_count == 2
    sleep.assert_called_once_with(.01)
    assert json.loads(target.with_suffix(".tmp").read_text()) == {"cycle": 1}


def test_persistent_lock_preserves_previous_snapshot(tmp_path):
    target = tmp_path / "snapshot.json"
    target.write_text('{"cycle": 0}')
    with patch("gm_market_service.os.replace", side_effect=PermissionError()) as replace:
        with patch("gm_market_service.time.sleep"):
            with pytest.raises(PermissionError):
                atomic_json(target, {"cycle": 1})
    assert replace.call_count == 8
    assert json.loads(target.read_text()) == {"cycle": 0}
