from __future__ import annotations
import asyncio
import os
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from bot.config import settings
from bot.db.store import Store
from bot.services.forecast import run_forecast_data, today_local

API_VERSION = "v4.2.22"
app = FastAPI(title="SYNDICATE QUANT API", version=API_VERSION)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)

store = Store()
forecast_lock = asyncio.Lock()


def require_client_token(token: str | None) -> None:
    expected = os.getenv("IOS_API_TOKEN", "").strip()
    if not expected:
        raise HTTPException(status_code=503, detail="IOS_API_TOKEN is not configured")
    if not token or token != expected:
        raise HTTPException(status_code=401, detail="Unauthorized")


def sanitize_row(row: dict[str, Any]) -> dict[str, Any]:
    """Return only fields the mobile client needs; never expose raw SStats payloads."""
    keys = [
        "game_id", "home", "away", "league", "league_id", "date", "date_utc",
        "market", "selection", "odds", "p", "p_low", "fair", "ev", "robust_ev",
        "qcs", "dcs", "ms", "stake", "classification", "model", "n",
        "consensus_odds", "price_status", "odds_source", "market_bookmakers",
        "sharp_label", "player_adjustment_label", "referee_adjustment_label",
        "forecast_scope", "forecast_date",
    ]
    out = {k: row.get(k) for k in keys if k in row}
    for k in ("odds", "p", "p_low", "fair", "ev", "robust_ev", "qcs", "dcs", "ms", "stake", "n", "consensus_odds"):
        if k in out and out[k] is not None:
            try: out[k] = float(out[k])
            except (TypeError, ValueError): out[k] = None
    return out


@app.get("/health")
async def health() -> dict[str, Any]:
    return {"status": "ok", "engine": API_VERSION}


@app.get("/v1/status")
async def status(x_client_token: str | None = Header(default=None, alias="X-Client-Token")):
    require_client_token(x_client_token)
    return {"status": "ok", "engine": API_VERSION, "forecast_date": today_local(settings)}


@app.get("/v1/forecast")
async def forecast(
    scope: str = Query("top", pattern="^(top|all)$"),
    x_client_token: str | None = Header(default=None, alias="X-Client-Token"),
):
    require_client_token(x_client_token)
    async with forecast_lock:
        try:
            rows = await run_forecast_data(store, settings, scope)
        except Exception as exc:
            raise HTTPException(status_code=502, detail=str(exc)[:1200]) from exc
    return {
        "engine": API_VERSION,
        "scope": scope,
        "forecast_date": today_local(settings),
        "count": len(rows),
        "rows": [sanitize_row(r) for r in rows],
    }


@app.get("/v1/daily")
async def daily(x_client_token: str | None = Header(default=None, alias="X-Client-Token")):
    require_client_token(x_client_token)
    date = today_local(settings)
    saved = store.daily_forecast(date) or {"created_at": None, "rows": []}
    rows = saved.get("rows") or []
    return {
        "engine": API_VERSION,
        "forecast_date": date,
        "created_at": saved.get("created_at"),
        "count": len(rows),
        "rows": [sanitize_row(r) for r in rows],
    }


@app.get("/v1/stats")
async def stats(x_client_token: str | None = Header(default=None, alias="X-Client-Token")):
    require_client_token(x_client_token)
    return {"engine": API_VERSION, **store.stats()}
