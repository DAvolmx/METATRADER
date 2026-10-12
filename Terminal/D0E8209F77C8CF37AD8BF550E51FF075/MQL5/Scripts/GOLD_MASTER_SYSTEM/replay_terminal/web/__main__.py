"""python -m web  ->  servidor en http://127.0.0.1:8000 (solo local)."""
import argparse
import webbrowser

import uvicorn

from core.logging_setup import setup_logging
from web.server import create_app

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--no-browser", action="store_true")
    a = ap.parse_args()
    setup_logging()
    if not a.no_browser:
        webbrowser.open(f"http://127.0.0.1:{a.port}")
    uvicorn.run(create_app(), host="127.0.0.1", port=a.port, log_level="warning")
