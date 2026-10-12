"""
Barreras arquitectónicas verificadas por código:
  * Solo mt5/execution.py puede llamar a order_send.
  * Paper trading, backtest, SMC, replay y simulación no importan MetaTrader5.
  * Nunca se guardan contraseñas en config/.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).parent.parent
SRC = [p for p in ROOT.rglob("*.py") if ".venv" not in p.parts and "tests" not in p.parts]


def test_only_execution_calls_order_send():
    offenders = [p.relative_to(ROOT).as_posix() for p in SRC
                 if re.search(r"order_send\s*\(", p.read_text(encoding="utf-8"))]
    assert offenders == []  # research build has no order-submission boundary


def test_isolated_packages_do_not_import_mt5():
    for pkg in ("trading", "smc", "replay", "simulation", "strategies", "data", "storage", "charts"):
        for p in (ROOT / pkg).glob("*.py"):
            src = p.read_text(encoding="utf-8")
            assert "import MetaTrader5" not in src, p
            assert "mt5.execution" not in src, p


def test_no_passwords_in_config():
    for p in (ROOT / "config").glob("*.json"):
        keys = json.dumps(json.loads(p.read_text(encoding="utf-8"))).lower()
        assert "password" not in keys and "contraseña" not in keys and "token" not in keys
