"""Verifica el API puente sin MT5: modo offline y lectura de ficheros del puente."""
import importlib
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
pytest.importorskip("fastapi")
from fastapi.testclient import TestClient  # noqa: E402


def _client(bridge_dir):
    import os
    os.environ["GM_BRIDGE_DIR"] = str(bridge_dir)
    import gm_live_api
    importlib.reload(gm_live_api)
    return TestClient(gm_live_api.app)


def test_offline_shapes(tmp_path):
    c = _client(tmp_path / "empty")
    s = c.get("/api/status").json()
    assert s["mt5"] is False and "bridge_dir" in s
    assert c.get("/api/account").json()["source"] == "offline"
    assert c.get("/api/positions").json()["positions"] == []
    assert c.get("/api/dom").json()["levels"] == []
    assert c.get("/api/flow").json()["source"] == "offline"
    snap = c.get("/api/snapshot").json()
    assert set(["status", "account", "positions", "quote", "dom", "flow"]).issubset(snap)


def test_reads_bridge_files(tmp_path):
    d = tmp_path / "GoldMaster"; d.mkdir()
    (d / "ea_state.txt").write_text("ts=123\nstatus=RUNNING\nequity=54.50\npositions=2\n", encoding="utf-8")
    (d / "intel.txt").write_text("symbol=XAUUSD\nvpin=0.38\nvwap=4182.4\ndxy_corr=-0.82\ncomposite=0.18\n", encoding="utf-8")
    (d / "news_calendar.csv").write_text("time,event,impact\n08:30,CPI,High\n", encoding="utf-8")
    c = _client(d)
    acct = c.get("/api/account").json()
    assert acct["source"] == "bridge" and acct["equity"] == 54.5 and acct["positions"] == 2
    flow = c.get("/api/flow").json()
    assert flow["source"] == "bridge" and flow["vpin"] == "0.38" and flow["dxy_corr"] == "-0.82"
    news = c.get("/api/news").json()
    assert news["source"] == "bridge" and news["events"][0]["event"] == "CPI"
