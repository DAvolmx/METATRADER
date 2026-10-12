"""
core/logging_setup.py — logs/app.log, logs/trading.log, logs/errors.log.
Formato: timestamp | level | module | event | message | account | symbol
Nunca se registran contraseñas, credenciales ni tokens.
"""
from __future__ import annotations

import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path

LOG_DIR = Path(__file__).parent.parent / "logs"
FMT = "%(asctime)s | %(levelname)-8s | %(name)s | %(event)s | %(message)s | %(account)s | %(symbol)s"


class _Defaults(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        for k in ("event", "account", "symbol"):
            if not hasattr(record, k):
                setattr(record, k, "-")
        return True


_done = False


def setup_logging(console: bool = True) -> None:
    global _done
    if _done:
        return
    LOG_DIR.mkdir(exist_ok=True)
    fmt = logging.Formatter(FMT)
    root = logging.getLogger()
    root.setLevel(logging.INFO)

    def handler(name: str, level=logging.INFO, logger_filter: str | None = None):
        h = RotatingFileHandler(LOG_DIR / name, maxBytes=5_000_000, backupCount=5, encoding="utf-8")
        h.setLevel(level)
        h.setFormatter(fmt)
        h.addFilter(_Defaults())
        if logger_filter:
            h.addFilter(logging.Filter(logger_filter))
        return h

    root.addHandler(handler("app.log"))
    root.addHandler(handler("errors.log", logging.ERROR))
    trading = logging.getLogger("ldz.trading")
    trading.addHandler(handler("trading.log"))
    if console:
        c = logging.StreamHandler()
        c.setFormatter(logging.Formatter("%(asctime)s | %(levelname)-8s | %(name)s | %(message)s"))
        root.addHandler(c)
    _done = True
