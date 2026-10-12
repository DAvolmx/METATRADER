"""
web/dashboard_api.py — Endpoints del panel integrado Gold Master Dashboard.
Se registra en el app de FastAPI llamando a register_dashboard(app, svc_holder).
"""
from __future__ import annotations
import json
import time
from pathlib import Path
from web.research_api import archive_summary


def register_dashboard(app, svc_holder: dict):
    """Añade /api/dashboard al app de FastAPI existente."""
    import asyncio

    def S():
        return svc_holder["svc"]

    async def call(fn, *a, **kw):
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, lambda: S().run(fn, *a, **kw))

    @app.get("/api/dashboard")
    async def dashboard():
        """
        Panel unificado:
        - cuenta MT5 en vivo
        - reglas activas del Adaptive EA (rules_db.json)
        - hipótesis del motor adaptativo (hypotheses.json)
        - analytics snapshot (market_snapshot.json)
        - estado de compilación de los 5 EAs
        """
        BASE    = Path(__file__).parents[2]
        RUNTIME = BASE / "python" / "runtime"
        MQL5    = Path(__file__).parents[4]
        EA_DIR  = MQL5 / "Experts" / "GOLD_MASTER_SYSTEM"

        # ── MT5 account ──────────────────────────────────────────────
        try:
            mt5_data = await call(S().monitor)
        except Exception:
            mt5_data = {}


        # ── Reglas activas (rules_db.json) ───────────────────────────
        rules = []
        try:
            raw = json.loads((RUNTIME / "rules_db.json").read_text(encoding="utf-8"))
            for r in raw.get("rules", []):
                if r.get("active", True):
                    rules.append({
                        "name":           r.get("name", ""),
                        "score":          round(float(r.get("score", 0)), 3),
                        "win_rate":       round(float(r.get("win_rate", 0)), 3),
                        "profit_factor":  round(float(r.get("profit_factor", 0)), 2),
                        "expectancy_r":   round(float(r.get("expectancy_r", 0)), 3),
                        "evidence_trades":int(r.get("evidence_trades", 0)),
                        "tf":             r.get("tf", ""),
                        "asset":          r.get("asset", ""),
                        "decay_trades":   int(r.get("decay_trades", 0)),
                    })
            rules.sort(key=lambda x: x["score"], reverse=True)
        except Exception:
            rules = []

        # ── Hipótesis (hypotheses.json) ───────────────────────────────
        hyps = []
        try:
            raw_h = json.loads((RUNTIME / "hypotheses.json").read_text(encoding="utf-8"))
            hypotheses = raw_h.get("hypotheses", [])
            for h in (hypotheses.values() if isinstance(hypotheses, dict) else hypotheses):
                hyps.append({
                    "name":          h.get("name", ""),
                    "state":         h.get("state", ""),
                    "n_trades":      int(h.get("n_trades", 0)),
                    "win_rate":      round(float(h.get("win_rate", 0)), 3),
                    "profit_factor": round(float(h.get("profit_factor", 0)), 2),
                    "score":         round(float(h.get("score", 0)), 3),
                    "description":   h.get("description", ""),
                    "tf":            h.get("tf", ""),
                })
            hyps.sort(key=lambda x: x["score"], reverse=True)
        except Exception:
            hyps = []


        # ── Analytics snapshot (market_snapshot.json) ─────────────────
        analytics = {"fresh": False, "age_s": -1, "assets": {}}
        try:
            snap = json.loads((RUNTIME / "market_snapshot.json").read_text(encoding="utf-8"))
            age  = time.time() - float(snap.get("ts", 0))
            analytics = {
                "fresh":   abs(age) < 30,
                "age_s":   round(age, 1),
                "assets":  snap.get("assets", {}),
                "session": snap.get("session", ""),
            }
        except Exception:
            pass

        # ── Estado de EAs compilados ──────────────────────────────────
        ea_names = [
            "GOLD_MASTER_GUARDIAN_EA",
            "GOLD_MASTER_STRUCTURE_EA",
            "GOLD_MASTER_SCALPER_EA",
            "GOLD_MASTER_PULLBACK_EA",
            "GOLD_ADAPTIVE_EA",
        ]
        ea_status = []
        for name in ea_names:
            ex5 = EA_DIR / (name + ".ex5")
            ea_status.append({
                "name":     name,
                "compiled": ex5.exists(),
                "mtime":    round(ex5.stat().st_mtime) if ex5.exists() else None,
            })

        return {
            "ts":           round(time.time()),
            "mt5":          mt5_data,
            "active_rules": rules,
            "hypotheses":   hyps,
            "analytics":    analytics,
            "ea_status":    ea_status,
            "execution":    "disabled",
            "research":     archive_summary(),
        }

    @app.get("/api/dashboard/rules_db")
    async def rules_db_full():
        """Devuelve rules_db.json completo (para tabla de reglas con historial)."""
        path = Path(__file__).parents[2] / "python" / "runtime" / "rules_db.json"
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return {"rules": [], "error": "no_file"}

    @app.get("/api/dashboard/hypotheses")
    async def hypotheses_full():
        """Devuelve hypotheses.json completo."""
        path = Path(__file__).parents[2] / "python" / "runtime" / "hypotheses.json"
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return {"hypotheses": {}, "error": "no_file"}
