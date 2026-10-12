"""
Pruebas de TODOS los endpoints de la API web (FastAPI TestClient, sin MT5).
Se usa la fuente DEMO (datos aleatorios rotulados como DEMO).
"""
import pytest

fastapi = pytest.importorskip("fastapi")
from fastapi.testclient import TestClient  # noqa: E402

from web.server import create_app  # noqa: E402
from web.service import TradingService  # noqa: E402


@pytest.fixture(scope="module")
def client(tmp_path_factory):
    svc = TradingService(db_path=tmp_path_factory.mktemp("web") / "w.db", mt5_enabled=False)
    with TestClient(create_app(svc)) as c:
        yield c


def ok(r):
    assert r.status_code == 200, r.text
    return r.json()


def test_index_and_static(client):
    assert "Lightweight" in client.get("/static/vendor/lightweight-charts.js").text[:300]
    assert "LDZ Trading Terminal" in client.get("/").text
    assert client.get("/static/app.js").status_code == 200


def test_status_and_mt5_disabled(client):
    s = ok(client.get("/api/status"))
    assert s["mode"] == "REPLAY" and s["real_enabled"] is False and s["loaded"] is False
    assert client.post("/api/connect").status_code == 400
    assert ok(client.get("/api/symbols?q=XAU")) == []
    assert isinstance(ok(client.get("/api/history")), list)
    assert ok(client.get("/api/monitor"))["mt5"] in ("DISCONNECTED", "ERROR")


def test_requires_load_first(client):
    r = client.post("/api/replay/step")
    assert r.status_code in (200, 400)


def test_load_demo_and_frame(client):
    r = ok(client.post("/api/load", json={"source": "DEMO", "base_tf": "M5", "start": "2026-08-20T10:00",
                                          "synthetic": True, "seed": 3, "chart_tfs": ["H4", "H1", "M15", "M5"]}))
    assert r["symbol"] == "DEMO" and r["loaded"] and r["mode"] == "REPLAY"
    f = ok(client.get("/api/frame?tfs=H4,H1,M15,M5&limit=300"))
    clock = f["state"]["clock"]
    for tf, mins in (("H4", 240), ("H1", 60), ("M15", 15), ("M5", 5)):
        c = f["charts"][tf]
        assert c["bars"] and all(b["time"] + mins * 60 <= clock for b in c["bars"]), tf   # sin futuro
        assert "smc" in c and c["smc"]["state"] in ("UNKNOWN", "BULLISH", "BEARISH", "RANGING")


def test_replay_endpoints(client):
    s0 = ok(client.get("/api/state"))
    s1 = ok(client.post("/api/replay/step?n=12"))
    assert s1["idx"] == s0["idx"] + 12 and s1["moved"] == 12
    s2 = ok(client.post("/api/replay/back?n=2"))
    assert s2["idx"] == s1["idx"] - 2 and s2["can_trade"] is False      # mirando el pasado
    ok(client.post("/api/replay/step?n=2"))
    s3 = ok(client.post("/api/replay/jump?t=2026-08-21T12:00"))
    assert s3["clock"] <= 1787400000 + 10 ** 9
    s4 = ok(client.post("/api/replay/reset"))
    assert s4["idx"] == s0["idx"]
    ok(client.post("/api/replay/jump?t=2026-08-21T12:00"))


def test_bars_smc_any_tf(client):
    b = ok(client.get("/api/bars?tf=D1&limit=50"))
    assert b["tf"] == "D1"
    m = ok(client.get("/api/smc?tf=M15"))
    assert set(m) >= {"events", "fvgs", "order_blocks", "liquidity", "swings", "range", "state"}
    assert client.get("/api/bars?tf=X9").status_code == 422


def test_smc_config(client):
    cfg = ok(client.post("/api/smc/config", json={"swing_left_bars": 3, "ranging_enabled": False}))
    assert cfg["swing_left_bars"] == 3 and cfg["ranging_enabled"] is False
    ok(client.post("/api/smc/config", json={"swing_left_bars": 5, "ranging_enabled": True}))


def test_paper_order_flow(client):
    pv = ok(client.post("/api/order/preview", json={"direction": "BUY", "sl_mode": "POINTS", "sl": 300, "tp": 2}))
    assert pv["route"] == "SIMULACION" and pv["volume"] > 0 and pv["rr"] == 2.0
    r = ok(client.post("/api/order", json={"direction": "BUY", "sl_mode": "POINTS", "sl": 300, "tp": 2}))
    t = r["trade"]
    assert t["entry_price"] == r["ask"] or t["entry_price"] > 0
    assert any(x["id"] == t["id"] for x in r["trades"])
    bad = client.post("/api/order", json={"direction": "BUY", "sl_mode": "PRICE", "sl": 999999})
    assert bad.status_code == 400
    r2 = ok(client.post("/api/order", json={"direction": "SELL", "use_risk": False, "volume": 0.05}))
    ok(client.post("/api/replay/step?n=50"))
    ok(client.post(f"/api/close?trade_id={r2['trade']['id']}"))
    assert client.post("/api/close?trade_id=99999").status_code == 400
    ok(client.post("/api/close"))
    st = ok(client.get("/api/state"))
    assert all(x["status"] != "OPEN" for x in st["trades"])


def test_real_trading_blocked_without_live(client):
    assert client.post("/api/real/authorize?login=123").status_code == 400
    assert client.post("/api/real/send?token=nope").status_code == 400
    assert ok(client.get("/api/real/positions")) == []
    assert client.post("/api/real/close?ticket=1").status_code == 400
    assert ok(client.post("/api/real/kill"))["real_enabled"] is False
    assert client.post("/api/live?on=true").status_code == 400
    assert client.get("/api/live/tick").status_code == 400


def test_drawings_crud(client):
    d = ok(client.post("/api/drawings", json={"timeframe": "H1", "kind": "trend",
                                              "coordinates": {"t1": "2026-08-20T10:00:00+00:00", "p1": 2300,
                                                              "t2": "2026-08-20T14:00:00+00:00", "p2": 2310}}))
    ok(client.post("/api/drawings", json={"id": d["id"], "timeframe": "H1", "kind": "trend",
                                          "coordinates": {"t1": "2026-08-20T10:00:00+00:00", "p1": 2301,
                                                          "t2": "2026-08-20T15:00:00+00:00", "p2": 2311},
                                          "style": {"color": "#00ff00"}}))
    lst = ok(client.get("/api/drawings?tf=H1"))
    assert lst[0]["coordinates"]["p1"] == 2301 and lst[0]["style"]["color"] == "#00ff00"
    ok(client.delete(f"/api/drawings/{d['id']}"))
    assert ok(client.get("/api/drawings?tf=H1")) == []
    assert client.post("/api/drawings", json={"timeframe": "H1", "kind": "nope", "coordinates": {}}).status_code == 422


def test_backtest_and_visibility(client):
    r = ok(client.post("/api/backtest", json={"bias_tf": "H1", "risk_pct": 0.5}))
    s = r["statistics"]
    assert s["total_trades"] == len(r["trades"]) and r["equity"] and r["drawdown"]
    assert r["smc_version"] and r["strategy_version"] == "1.0"
    vis = ok(client.get("/api/backtest/visible"))
    clock = ok(client.get("/api/state"))["clock"]
    assert all(t["entry_time"] <= clock for t in vis)
    assert all(t["exit_time"] is None or t["exit_time"] <= clock for t in vis)   # no revela salidas futuras
    if r["trades"]:
        st = ok(client.post("/api/replay/next_trade"))
        assert st["clock"] > clock
    assert "backtest_" in ok(client.post("/api/backtest/export"))["folder"]


def test_unified_dashboard_and_challenge(client):
    panel = ok(client.get("/api/dashboard"))
    assert panel["execution"] == "disabled"
    archive = ok(client.get('/api/research/archive'))
    assert archive['promotion_allowed'] is False
    if archive['available']:
        assert client.get(archive['report_url']).status_code == 200
    assert any(e["name"] == "GOLD_ADAPTIVE_EA" and e["compiled"] for e in panel["ea_status"])
    result = ok(client.post("/api/backtest", json={"initial_balance": 10,
        "challenge": True, "challenge_goal": 100, "challenge_days": 3,
        "strategy": "SMC_FVG", "risk_pct": 1}))
    assert result["challenge"]["goal"] == 100
    assert result["challenge"]["max_equity"] >= 0
    assert result["challenge"]["rejected_orders"] == result["statistics"]["rejected_orders"]


def test_synthetic_mode_after_data(client):
    st = ok(client.get("/api/state"))
    ok(client.post(f"/api/replay/step?n={st['n_real'] - st['idx'] + 5}"))
    st = ok(client.get("/api/state"))
    assert st["synthetic_zone"] and st["mode"] == "SYNTHETIC"
    assert client.post("/api/real/authorize?login=1").status_code == 400


# ---------------------------------------------------------------- pestañas y aprendizaje
def test_multiple_tabs_are_independent(client):
    a = ok(client.post("/api/load?sid=tabA", json={"source": "DEMO", "base_tf": "M5", "start": "2026-08-20T10:00"}))
    b = ok(client.post("/api/load?sid=tabB", json={"source": "DEMO", "base_tf": "M15", "start": "2026-08-24T10:00"}))
    ok(client.post("/api/replay/step?n=30&sid=tabA"))
    sa, sb = ok(client.get("/api/state?sid=tabA")), ok(client.get("/api/state?sid=tabB"))
    assert sa["idx"] == a["idx"] + 30 and sb["idx"] == b["idx"] and sb["base_tf"] == "M15"
    tabs = {t["sid"]: t for t in ok(client.get("/api/sessions"))}
    assert {"tabA", "tabB"} <= set(tabs) and tabs["tabA"]["price"] and tabs["tabB"]["base_tf"] == "M15"
    ok(client.delete("/api/sessions/tabB"))
    assert "tabB" not in {t["sid"] for t in ok(client.get("/api/sessions"))}
    assert client.delete("/api/sessions/nope").status_code == 400
    assert client.get("/api/state?sid=bad id").status_code == 422


def test_explain(client):
    items = ok(client.get("/api/learn/explain?tf=M15&sid=tabA"))
    assert items and all({"title", "text", "time", "kind"} <= set(i) for i in items)
    clock = ok(client.get("/api/state?sid=tabA"))["clock"]
    assert all(i["time"] <= clock for i in items)                     # nada del futuro


def test_quiz_flow(client):
    q = ok(client.post("/api/learn/quiz?guess=UP&horizon=6&sid=tabA"))
    assert q["quiz_open"]["guess"] == "UP"
    assert client.post("/api/learn/quiz?guess=DOWN&horizon=6&sid=tabA").status_code == 400   # solo uno
    r = ok(client.post("/api/learn/quiz/reveal?sid=tabA"))
    assert r["result"]["correct"] in (True, False) and r["quiz_total"] == 1 and r["quiz_open"] is None
    st = ok(client.get("/api/learn/quiz?sid=tabA"))
    assert st["quiz_accuracy"] in (0.0, 100.0)


def test_start_at_and_random(client):
    s1 = ok(client.post("/api/replay/start_at?t=2026-08-18T12:00&sid=tabA"))
    s2 = ok(client.post("/api/replay/start_at?random=true&sid=tabA"))
    assert s1["session"] != s2["session"] and all(t["status"] != "OPEN" for t in s2["trades"])
    ok(client.post("/api/replay/reset?sid=tabA"))
    assert ok(client.get("/api/state?sid=tabA"))["idx"] == s2["idx"]


def test_journal(client):
    r = ok(client.post("/api/order?sid=tabA", json={"direction": "BUY", "sl": 300, "tp": 2,
                                                    "setup": "BOS+FVG", "note": "retroceso a FVG H1"}))
    tid = r["trade"]["id"]
    ok(client.post("/api/replay/step?n=200&sid=tabA"))
    ok(client.post("/api/close?sid=tabA"))
    ok(client.post(f"/api/journal/{tid}?sid=tabA", json={"lesson": "entré tarde"}))
    j = ok(client.get("/api/journal?sid=tabA"))
    row = next(x for x in j["trades"] if x["id"] == tid)
    assert row["setup"] == "BOS+FVG" and row["lesson"] == "entré tarde" and row["note"].startswith("retroceso")
    assert any(s["setup"] == "BOS+FVG" for s in j["by_setup"])
    assert client.post("/api/journal/9999?sid=tabA", json={}).status_code == 400
