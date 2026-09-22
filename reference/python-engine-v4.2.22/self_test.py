from __future__ import annotations
import ast
import importlib
import pathlib
import sys
import os

ROOT = pathlib.Path(__file__).resolve().parent

def check_compile():
    files = list(ROOT.rglob("*.py"))
    for f in files:
        ast.parse(f.read_text(encoding="utf-8"))
    print(f"[OK] AST parse: {len(files)} Python files")

def check_imports():
    modules = [
        "bot.api.sstats", "bot.config", "bot.db.store", "bot.backtest",
        "bot.auto_backtest", "bot.engine.data", "bot.engine.player",
        "bot.engine.referee", "bot.engine.sharp", "bot.engine.pricing",
        "bot.engine.portfolio", "bot.engine.odds", "bot.engine.analysis",
        "bot.engine.calibration", "bot.engine.scanner", "bot.history",
        "bot.models.distributions", "server.app", "bot.main",
    ]
    loaded=0; optional_missing=[]
    for name in modules:
        try:
            importlib.import_module(name); loaded += 1
        except ModuleNotFoundError as e:
            if name == 'bot.main' and getattr(e, 'name', None) == 'aiogram':
                optional_missing.append('aiogram (install requirements.txt)')
                continue
            raise
    print(f"[OK] Module imports: {loaded}/{len(modules)}")
    if optional_missing:
        print('[WARN] Telegram runtime dependency not installed in this environment: ' + ', '.join(optional_missing))

def check_engine():
    from bot.engine.analysis import model_match
    from bot.engine.odds import classify_market, build_market_map, key_bookmakers
    hist = [{
        "gf": 1, "ga": 0, "xg": 1.2, "opp_xg": .8,
        "corners": 5, "opp_corners": 3, "cards": 2, "opp_cards": 2,
        "fouls": 10, "opp_fouls": 11, "players": []
    } for _ in range(10)]
    m = model_match(hist, hist)
    assert m is not None
    assert abs(sum((m["p_home"], m["p_draw"], m["p_away"])) - 1) < 1e-6
    assert classify_market("Total Fouls") is None
    assert classify_market("Total Goals") == "GOALS"
    rows = [
        {"market": "Total Goals", "name": "Over 2.5", "odds": 2.0, "bookmaker": "A", "bookmaker_id": 1},
        {"market": "Total Goals", "name": "Over 2.5", "odds": 2.1, "bookmaker": "B", "bookmaker_id": 2},
    ]
    assert build_market_map(rows, "GOALS")["Over2.5"] == 2.05
    assert len(key_bookmakers(rows, "GOALS", "Over2.5")) == 2
    print("[OK] Deterministic model/odds smoke tests")

def check_config():
    from bot.config import settings
    required = ("sstats_api_key", "owner_user_id")
    missing = [x for x in required if not getattr(settings, x, None)]
    if missing:
        raise RuntimeError("Missing required .env settings: " + ", ".join(missing))
    print("[OK] Configuration loaded; credentials are present (not printed)")

if __name__ == "__main__":
    check_compile()
    check_imports()
    check_engine()
    check_config()
    print("SELF_TEST_OK")
